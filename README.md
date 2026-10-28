# VideoTube Lite

Una página HTML/CSS para enseñar este recorrido:

**Editar → commit → push a main → GitHub Actions → S3 → ver el cambio.**

No requiere compilación, npm, backend, EC2, RDS ni CloudFront. La página es una muestra estática: las tarjetas no reproducen videos. El sitio público de S3 utiliza HTTP.

## Archivos

```text
lite/
├── site/
│   ├── index.html
│   └── styles.css
├── .github/workflows/deploy.yml
├── infra/
│   ├── cloudformation/stack.yml
│   └── scripts/bootstrap.sh
├── .gitattributes
└── README.md
```

## 1. Subir la página manualmente

El bucket de esta práctica es `videotube-lite-leirbag-2026`, en `us-east-1`.

1. Puedes abrir `site/index.html` directamente en tu navegador para ver la página local.
2. En S3, entra en el bucket → **Objects → Upload → Add files**.
3. Selecciona **los dos archivos dentro de `site`**: `index.html` y `styles.css`.
4. Pulsa **Upload**. Deben quedar en la raíz del bucket, sin una carpeta `site/` delante.
5. En **Properties → Static website hosting**, abre el endpoint del sitio web.

El alojamiento debe estar habilitado con `index.html` como documento inicial y la política debe permitir `s3:GetObject` público. Sube solo los archivos de `site/`, no `infra/`, `.github/` ni el proyecto completo.

## 2. Preparar el repositorio de la clase

Copia **el contenido de `lite/`**, incluida la carpeta oculta `.github`, a la raíz de un repositorio independiente, por ejemplo `videotube-lite`. Usa la rama `main`.

GitHub solo descubre los workflows en `.github/workflows` de la raíz. Mientras este archivo esté en `Video-tube/lite/.github/workflows`, es una plantilla y no se ejecutará. El workflow del proyecto completo permanece independiente; no uses sus variables para esta práctica.

## 3. Conectar GitHub con AWS

Puedes configurar IAM/OIDC manualmente durante la explicación o usar la infraestructura incluida como preparación previa. El workflow no necesita CloudFormation para publicar: solo necesita el bucket y el rol IAM.

`stack.yml` describe los recursos. `bootstrap.sh` prepara su creación inicial desde AWS CloudShell, comprueba cuenta/región, reutiliza el proveedor GitHub OIDC si existe y muestra un change set antes de ejecutarlo. No instala ni publica la página.

Desde la raíz del repositorio Lite en CloudShell, sustituye `TU_USUARIO/videotube-lite` por el repositorio definitivo:

```bash
bash infra/scripts/bootstrap.sh TU_USUARIO/videotube-lite videotube-lite us-east-1 videotube-lite-leirbag-2026
```

Con el último argumento, **se reutiliza el bucket que ya creaste**: no se importa en CloudFormation ni se cambian su política, sus archivos o su alojamiento. Solo se crea el rol y, si falta, el proveedor OIDC. Sin ese argumento, la plantilla crea un bucket nuevo con nombre generado por AWS y una política de lectura pública.

El script necesita AWS CLI, curl y jq, disponibles en CloudShell, y permisos para consultar S3/IAM y crear los recursos de la plantilla. La cuenta puede bloquear políticas públicas a nivel global; el script no cambia esa configuración. No uses `bootstrap.sh` si prefieres continuar toda la configuración manual con la guía del chat.

El script es solo para el primer despliegue. Si existe el stack, se detiene para que revises su estado y sus change sets; no elimina ni actualiza recursos automáticamente. Si presionas Enter en la confirmación, revisa/ejecuta el change set en CloudFormation, sin volver a lanzar el script. Tras ejecutarlo, espera `CREATE_COMPLETE`.

### Identidad OIDC de GitHub

El script consulta la API pública de GitHub y construye el subject con IDs inmutables para un repositorio nuevo. Si el repositorio es privado o usa el formato anterior, proporciona su subject exacto mediante `GITHUB_OIDC_SUBJECT`. Ejemplo para un repositorio antiguo que conserve el formato sin IDs:

```bash
GITHUB_OIDC_SUBJECT='repo:TU_USUARIO/TU_REPO:ref:refs/heads/main' \
  bash infra/scripts/bootstrap.sh TU_USUARIO/TU_REPO videotube-lite us-east-1 videotube-lite-leirbag-2026
```

La confianza se limita a esa identidad y a `main`, con audiencia `sts.amazonaws.com`. No añadas `environment:` al job sin adaptar el subject. Los repositorios con subjects personalizados requieren adaptar la plantilla a su valor exacto. No se guardan Access Keys en GitHub.

## 4. Variables del workflow

En el repositorio Lite: **Settings → Secrets and variables → Actions → Variables**.

| Variable | Valor |
|---|---|
| `AWS_ROLE_ARN` | Output `AWSRoleArn` de CloudFormation o ARN del rol creado manualmente |
| `AWS_REGION` | `us-east-1` |
| `S3_BUCKET_NAME` | `videotube-lite-leirbag-2026` (o output `S3BucketName` si creaste otro) |
| `WEBSITE_URL` | Endpoint HTTP de **S3 → Properties → Static website hosting**, no la URL de la consola |

El rol solo permite listar el bucket y subir/borrar sus objetos. No concede permisos para EC2, RDS ni cambios de infraestructura.

## 5. Demostración en clase

1. Muestra la página publicada con **Versión 1**.
2. Abre `site/index.html` y cambia `Versión 1` por `Versión 2`.
3. Haz commit y push a `main`.
4. En **Actions → Publicar VideoTube Lite**, observa los jobs `validar` y `publicar`.
5. Abre la URL del resumen y recarga la página. Ahora debe mostrar **Versión 2**.
6. Opcional: cambia `--accent` en `site/styles.css` y repite el proceso.

`validar` comprueba que HTML y CSS existen, tienen contenido y están enlazados; no demuestra que todo el HTML/CSS sea correcto. Los pull requests solo validan. Los pushes a `main` que cambian `site/` o el workflow publican; también puedes usar **Run workflow** en `main`.

`publicar` obtiene credenciales temporales con OIDC, ejecuta `aws s3 sync` y descarga HTML/CSS desde el sitio para compararlos con el commit. La opción **`--delete` elimina del bucket los archivos que no están en `site/`**: usa un bucket exclusivo para esta página. La configuración de caché permite ver cambios al recargar; los archivos subidos previamente a mano pueden necesitar una recarga forzada la primera vez.

Si faltan variables, el job falla con un mensaje. Si falla OIDC, revisa repo/rama/subject y audiencia. Si aparece 403 en la web, revisa la política y los bloqueos de acceso público del bucket y de la cuenta. Si aparece 404, revisa que `index.html` esté en la raíz.

## Limpieza

Eliminar el stack elimina el rol creado. Un bucket creado por esta plantilla y un proveedor OIDC creado por ella **se conservan** mediante `Retain`: revisa sus recursos antes de eliminarlos manualmente. El proveedor puede servir a otros repositorios. Un bucket o proveedor reutilizado nunca pasa a ser propiedad de este stack. No elimines recursos de otros proyectos.

## Referencias

- [S3: permisos para un sitio web](https://docs.aws.amazon.com/AmazonS3/latest/userguide/WebsiteAccessPermissionsReqd.html)
- [GitHub: formatos del subject OIDC](https://docs.github.com/en/actions/reference/security/oidc)
- [AWS: proveedor OIDC en CloudFormation](https://docs.aws.amazon.com/AWSCloudFormation/latest/TemplateReference/aws-resource-iam-oidcprovider.html)
- [Acción oficial de credenciales AWS](https://github.com/aws-actions/configure-aws-credentials)
