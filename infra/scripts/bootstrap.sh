#!/usr/bin/env bash
# Preparación INICIAL desde AWS CloudShell. No publica archivos de la página.
set -euo pipefail
export AWS_PAGER=''

if [[ $# -lt 1 || $# -gt 4 ]]; then
  echo 'Uso: bash infra/scripts/bootstrap.sh USUARIO/REPO [STACK] [REGION] [BUCKET_EXISTENTE]'
  exit 1
fi
repo="$1"
stack="${2:-videotube-lite}"
region="${3:-us-east-1}"
bucket="${4:-}"
[[ "$repo" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]] || { echo 'Repositorio inválido: usa USUARIO/REPO.'; exit 1; }
[[ "$stack" =~ ^[A-Za-z][A-Za-z0-9-]{0,127}$ ]] || { echo 'Nombre de stack inválido.'; exit 1; }
for command in aws curl jq; do
  command -v "$command" >/dev/null || { echo "Falta instalar $command."; exit 1; }
done
script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
template="$script_dir/../cloudformation/stack.yml"
account="$(aws sts get-caller-identity --query Account --output text --region "$region")"
echo "Cuenta: $account | Región: $region | Stack: $stack | Repositorio: $repo"

# No convertir errores de permisos en 'stack inexistente'.
stacks="$(aws cloudformation list-stacks --region "$region" --output json)"
if jq -e --arg name "$stack" '.StackSummaries[] | select(.StackName == $name and .StackStatus != "DELETE_COMPLETE")' <<< "$stacks" >/dev/null; then
  echo 'Ese stack ya existe. Revisa su estado y sus change sets en CloudFormation.'
  echo 'Este script solo hace la preparación inicial; no actualiza ni elimina stacks existentes.'
  exit 1
fi

if [[ -n "$bucket" ]]; then
  aws s3api head-bucket --bucket "$bucket" --expected-bucket-owner "$account" --region "$region"
  bucket_region="$(aws s3api get-bucket-location --bucket "$bucket" --expected-bucket-owner "$account" --query LocationConstraint --output text)"
  [[ "$bucket_region" == None ]] && bucket_region=us-east-1
  [[ "$bucket_region" == EU ]] && bucket_region=eu-west-1
  [[ "$bucket_region" == "$region" ]] || { echo "El bucket está en $bucket_region; usa esa región."; exit 1; }
  aws s3api get-bucket-website --bucket "$bucket" --expected-bucket-owner "$account" --region "$region" >/dev/null
  echo "Se reutilizará $bucket. Su política y alojamiento web no serán modificados."
else
  echo 'Se creará un bucket nuevo con lectura pública para los archivos de la web.'
fi

providers="$(aws iam list-open-id-connect-providers --output json)"
provider="$(jq -r '.OpenIDConnectProviderList[].Arn | select(endswith(":oidc-provider/token.actions.githubusercontent.com"))' <<< "$providers")"
if [[ -n "$provider" ]]; then
  provider_config="$(aws iam get-open-id-connect-provider --open-id-connect-provider-arn "$provider" --output json)"
  jq -e '.ClientIDList | index("sts.amazonaws.com") != null' <<< "$provider_config" >/dev/null || {
    echo 'El proveedor OIDC existente no permite sts.amazonaws.com. Revisa su configuración en IAM.'; exit 1;
  }
fi

# Los repositorios nuevos usan IDs inmutables. Para un repo antiguo se puede
# pasar su subject exacto mediante GITHUB_OIDC_SUBJECT (ver README).
subject="${GITHUB_OIDC_SUBJECT:-}"
if [[ -z "$subject" ]]; then
  repo_info="$(curl --fail --silent --show-error --connect-timeout 10 --max-time 30 "https://api.github.com/repos/$repo")" || {
    echo 'No se pudo consultar el repositorio público. Revisa el nombre o define GITHUB_OIDC_SUBJECT.'; exit 1;
  }
  subject="$(jq -er '"repo:\(.owner.login)@\(.owner.id)/\(.name)@\(.id):ref:refs/heads/main"' <<< "$repo_info")"
fi
subject_pattern='^repo:[A-Za-z0-9_.-]+(@[0-9]+)?/[A-Za-z0-9_.-]+(@[0-9]+)?:ref:refs/heads/main$'
[[ "$subject" =~ $subject_pattern ]] || { echo 'Subject OIDC inválido; debe identificar un repositorio y su rama main.'; exit 1; }
subject_repo="$(sed -E 's/^repo://; s/@[0-9]+//g; s/:ref:refs\/heads\/main$//' <<< "$subject")"
[[ "${subject_repo,,}" == "${repo,,}" ]] || { echo 'El subject OIDC no coincide con el repositorio indicado.'; exit 1; }
echo "Identidad de GitHub autorizada: $subject"

parameters="$(jq -n --arg bucket "$bucket" --arg provider "$provider" --arg subject "$subject" '[
  {ParameterKey:"ExistingBucketName",ParameterValue:$bucket},
  {ParameterKey:"ExistingOidcProviderArn",ParameterValue:$provider},
  {ParameterKey:"GitHubSubject",ParameterValue:$subject}
]')"
aws cloudformation validate-template --template-body "file://$template" --region "$region" >/dev/null
change_set="lite-$(date +%s)"
aws cloudformation create-change-set --stack-name "$stack" --change-set-name "$change_set" \
  --change-set-type CREATE --template-body "file://$template" --parameters "$parameters" \
  --capabilities CAPABILITY_IAM --region "$region" >/dev/null
if ! aws cloudformation wait change-set-create-complete --stack-name "$stack" --change-set-name "$change_set" --region "$region"; then
  aws cloudformation describe-change-set --stack-name "$stack" --change-set-name "$change_set" --region "$region" --query '[Status,StatusReason]' --output table
  exit 1
fi
aws cloudformation describe-change-set --stack-name "$stack" --change-set-name "$change_set" --region "$region" \
  --query 'Changes[].ResourceChange.{Action:Action,Resource:LogicalResourceId,Type:ResourceType}' --output table
echo 'Esto creará permisos IAM y, si corresponde, un bucket público. S3 genera cargos por uso.'
read -r -p "Escribe $stack para ejecutar (Enter solo lo deja preparado): " confirmation || confirmation=''
if [[ "$confirmation" != "$stack" ]]; then
  echo "Change set preparado: $change_set. Puedes revisarlo y ejecutarlo en CloudFormation."
  exit 0
fi
aws cloudformation execute-change-set --stack-name "$stack" --change-set-name "$change_set" --region "$region"
if ! aws cloudformation wait stack-create-complete --stack-name "$stack" --region "$region"; then
  echo 'La creación no terminó correctamente o se agotó la espera. Revisa Events antes de repetir acciones.'
  exit 1
fi
aws cloudformation describe-stacks --stack-name "$stack" --region "$region" --query 'Stacks[0].Outputs' --output table
echo 'Configura AWS_ROLE_ARN, AWS_REGION, S3_BUCKET_NAME y WEBSITE_URL en las variables de GitHub.'
echo 'Si reutilizaste un bucket, copia WEBSITE_URL desde S3 > Properties > Static website hosting.'
