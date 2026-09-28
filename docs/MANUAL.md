# Manual: Hermes Agent en Docker (macOS Intel)

Guía para reconstruir toda la infraestructura desde cero, sin ayuda externa. Incluye los errores reales que aparecieron durante el montaje y cómo se resolvieron.

**Contenido**

1. Qué se construye
2. Requisitos previos
3. Por qué Docker y no instalación nativa
4. Instalación paso a paso
5. Dashboard web
6. Operación diaria
7. Sesiones persistentes con Herdr (opcional)
8. GitHub CLI sin Homebrew y publicación
9. Errores comunes y soluciones
10. Reglas de oro
11. Pendientes

---

## 1. Qué se construye

```
Mac (host)
  ├── Herdr ............ sesiones de terminal persistentes (opcional)
  └── Docker Desktop
        └── Contenedor "hermes-agent" (Ubuntu 24.04)
              ├── Hermes Agent ──► OpenRouter API ──► modelo LLM
              └── Dashboard web (puerto 9118 interno, publicado en localhost:9119)
```

Resultado: un agente de IA corriendo aislado en un contenedor, con interfaz web en `http://localhost:9119`, configuración persistente y modelo gratuito vía OpenRouter.

## 2. Requisitos previos

- **Docker Desktop** instalado y abierto. Verificar: `docker --version`
- **Cuenta en OpenRouter** y una API key: openrouter.ai → Keys → Create Key (empieza con `sk-or-v1-`). Hay modelos con sufijo `:free` sin costo.
- **Cuenta de GitHub** (para publicar el proyecto).
- **Nota sobre Anthropic:** la API de Claude (console.anthropic.com) es un servicio de pago por uso, separado de claude.ai. Una cuenta gratuita de claude.ai no da acceso a la API. No es necesaria para arrancar.

## 3. Por qué Docker y no instalación nativa

En un Mac Intel de generación antigua, todas las rutas nativas fallaron:

| Intento | Resultado |
|---|---|
| Instalador de Hermes en macOS | Falla al compilar `cryptography` (faltan `pkg-config` y OpenSSL) |
| Homebrew para instalar esas dependencias | El instalador responde que solo soporta Apple Silicon |
| OrbStack (VM ligera) | Rechaza CPUs Intel fuera del rango 6ª a 10ª generación |
| Apps `.dmg` recientes | Mensaje de "no compatible" |

**Solución:** correr Hermes dentro de un contenedor Linux. En Linux los paquetes vienen precompilados y no hay que compilar nada.

## 4. Instalación paso a paso

### 4.1 Crear la carpeta del proyecto

```bash
mkdir -p ~/proyectos/hermes-infra
cd ~/proyectos/hermes-infra
git init
```

### 4.2 Dockerfile

```bash
cat > Dockerfile << 'EOF'
FROM ubuntu:24.04

RUN apt update && apt install -y curl git ca-certificates libatomic1 libstdc++6 socat && \
    rm -rf /var/lib/apt/lists/*

RUN curl -fsSL https://hermes-agent.nousresearch.com/install.sh | bash

ENV PATH="/root/.local/bin:/root/.hermes/bin:${PATH}"

WORKDIR /root
CMD ["bash"]
EOF
```

Por qué cada pieza:

- `libatomic1` y `libstdc++6`: sin ellas Node (que instala Hermes) falla con `libatomic.so.1: cannot open shared object file`.
- `socat`: reenvía el puerto del dashboard (ver sección 5).
- `ENV PATH` con `/root/.local/bin`: es donde el instalador deja el comando `hermes`. Sin esto, `hermes` no se encuentra fuera de una terminal interactiva.

### 4.3 Variables de entorno (API keys)

```bash
cat > .env.example << 'EOF'
ANTHROPIC_API_KEY=
OPENROUTER_API_KEY=sk-or-v1-PEGA-AQUI-TU-KEY
EOF

cp .env.example .env
nano .env
```

Reemplaza el valor de ejemplo por tu key real de OpenRouter. En `nano`: `Ctrl+O`, `Enter` para guardar y `Ctrl+X` para salir. Deja `ANTHROPIC_API_KEY` vacío si no la usas.

### 4.4 docker-compose.yml

```bash
cat > docker-compose.yml << 'EOF'
services:
  hermes:
    build: .
    container_name: hermes-agent
    restart: unless-stopped
    init: true
    ports:
      - "127.0.0.1:9119:9119"
    env_file:
      - .env
    volumes:
      - hermes-data:/root/.hermes
    stdin_open: true
    tty: true
    command: >
      bash -c "socat TCP-LISTEN:9119,fork,reuseaddr TCP:127.0.0.1:9118 &
      exec hermes dashboard --port 9118 --no-open"

volumes:
  hermes-data:
EOF
```

Por qué cada pieza:

- `restart: unless-stopped`: el contenedor vuelve a levantarse solo tras reiniciar Docker o el Mac.
- `init: true`: evita procesos zombi (`socat` crea un proceso por conexión).
- `127.0.0.1:9119:9119`: publica el puerto **solo en tu Mac**, no en tu red WiFi.
- `volumes: hermes-data`: la configuración, perfiles e historial sobreviven aunque recrees el contenedor.
- `command`: arranca el reenviador y el dashboard automáticamente.

### 4.5 .gitignore

```bash
cat > .gitignore << 'EOF'
.env
EOF
```

Impide subir tus API keys a GitHub por accidente.

### 4.6 Construir y levantar

```bash
docker compose up -d --build
```

La primera vez tarda entre 3 y 5 minutos. Un aviso amarillo sobre "commit information" es inofensivo. Verificar:

```bash
docker ps
docker logs hermes-agent
```

Debe aparecer el contenedor `hermes-agent` con estado `Up` y en los logs la línea `HERMES_DASHBOARD_READY port=9118`.

### 4.7 Configurar el modelo

```bash
docker exec -it hermes-agent bash
hermes model
```

En el asistente interactivo (flechas y Enter):

1. Elige **OpenRouter**.
2. Cuando pregunte por la API key detectada (`[K]eep / [R]eplace / [C]lear`), presiona `K`.
3. Elige un modelo cuyo nombre termine en `:free`. La lista cambia con el tiempo; si el que buscas no aparece, usa *Enter custom model name*. En esta instalación se usó `nvidia/nemotron-3-super-120b-a12b:free`.
4. Nivel de razonamiento: `medium`.

Verificar la configuración:

```bash
hermes config show
```

Debe mostrar tu key de OpenRouter (parcialmente oculta) y el modelo elegido. Prueba final:

```bash
hermes
```

Escribe un saludo. Si responde, todo funciona de punta a punta.

## 5. Dashboard web

Abre en el navegador: `http://localhost:9119`

**Por qué se necesita `socat`:** por defecto el dashboard escucha solo en `127.0.0.1` dentro del contenedor, y Docker entrega las conexiones desde otra dirección, por lo que el navegador mostraba `ERR_CONNECTION_RESET`. Desde el endurecimiento de seguridad de junio de 2026, Hermes se niega a escuchar en `0.0.0.0` sin autenticación configurada. La ayuda del propio comando recomienda "bind 127.0.0.1 + tunnel", y `socat` es ese túnel dentro del contenedor:

```
Navegador ──► localhost:9119 (Docker) ──► socat :9119 ──► dashboard 127.0.0.1:9118
```

Como Docker publica el puerto solo en `127.0.0.1` de tu Mac, únicamente tú puedes acceder.

## 6. Operación diaria

Desde `~/proyectos/hermes-infra`:

| Acción | Comando |
|---|---|
| Iniciar | `docker compose up -d` |
| Parar (conserva todo) | `docker compose stop` |
| Reiniciar | `docker compose restart` |
| Estado | `docker compose ps` |
| Logs | `docker logs hermes-agent` |
| Entrar al contenedor | `docker exec -it hermes-agent bash` |
| Chat por terminal (dentro) | `hermes` |
| Reconstruir tras cambiar el Dockerfile | `docker compose up -d --build` |

**Peligro:** `docker compose down -v` elimina el volumen `hermes-data` y pierdes configuración, perfiles e historial. `down` sin `-v` es seguro.

Alternativa gráfica: Docker Desktop → Containers → botones de play y stop.

Hermes incluye un comando de respaldo (`hermes backup`). Revisa sus opciones con `hermes backup --help` antes de usarlo.

## 7. Sesiones persistentes con Herdr (opcional)

Herdr mantiene tus terminales vivas aunque cierres la ventana. Se instala **en el Mac**, no dentro del contenedor.

```bash
curl -fsSL https://herdr.dev/install.sh | sh
echo 'export PATH="$HOME/.local/bin:$PATH"' >> ~/.zshrc
source ~/.zshrc
herdr --version
```

Uso básico:

- Ejecuta `herdr`. Se maneja con el mouse: un *workspace* por proyecto y *panes* que son terminales reales.
- Dentro de un pane ejecuta `docker exec -it hermes-agent bash`.
- Para desconectarte dejando todo corriendo: `Ctrl+B`, soltar y luego `Q`.
- Para volver: `herdr`.
- Para terminar la sesión y detener sus paneles: `herdr server stop`.

Si recreas el contenedor, los paneles deben volver a ejecutar `docker exec`.

## 8. GitHub CLI sin Homebrew y publicación

### 8.1 Instalar `gh` por terminal

Descargar con `curl` evita el bloqueo de Gatekeeper ("Apple no pudo verificar...") que sí aparece con instaladores bajados desde el navegador.

```bash
cd ~/Downloads
curl -s https://api.github.com/repos/cli/cli/releases/latest | grep "browser_download_url.*macOS_amd64.zip"
```

Copia la URL que muestra y úsala aquí:

```bash
curl -L -o gh.zip URL_QUE_MOSTRO_EL_COMANDO
unzip gh.zip
find . -name "gh" -type f
mv RUTA_QUE_ENCONTRO/gh ~/.local/bin/gh
chmod +x ~/.local/bin/gh
gh --version
```

No uses la URL con `latest/download/...` inventada: devuelve una respuesta de pocos bytes en vez del archivo.

### 8.2 Autenticar

```bash
gh auth login
```

Respuestas: `GitHub.com` → `HTTPS` → `Yes` → `Login with a web browser`. Copia el código que muestra, pégalo en el navegador y autoriza.

### 8.3 Publicar el proyecto

Antes de subir, confirma que `.env` no aparece:

```bash
cat .gitignore
git status
```

Luego:

```bash
git add .
git commit -m "Mensaje descriptivo"
gh repo create hermes-infra --public --source=. --remote=origin --push
```

**Público o privado:** para portafolio conviene público. Para proyectos con datos de clientes o información sensible usa `--private` y agrega colaboradores manualmente en Settings → Collaborators.

## 9. Errores comunes y soluciones

| Síntoma | Causa | Solución |
|---|---|---|
| `cryptography` falla al compilar en macOS (`Could not find openssl via pkg-config`) | Faltan `pkg-config` y OpenSSL; Homebrew no soporta Intel | Usar Docker (sección 3) |
| `Homebrew on macOS is only supported on Apple Silicon processors!` | Homebrew dejó de dar soporte a Intel | Usar Docker |
| OrbStack: `Intel CPUs older than Skylake ... not supported` | CPU fuera del rango soportado | Usar Docker Desktop |
| Build de Docker: `libatomic.so.1: cannot open shared object file` | Falta esa librería en Ubuntu base | Agregar `libatomic1` al `apt install` |
| `hermes: command not found` en `docker exec` sin `-it` o en el arranque | `hermes` vive en `/root/.local/bin`, fuera del PATH | `ENV PATH` con `/root/.local/bin` en el Dockerfile |
| `hermes config list` → "not a `hermes config` command" | El subcomando correcto es otro | Usar `hermes config show` |
| `hermes config set llm.provider ...` → "not a recognized config key" | Nombres de clave inventados | Usar el asistente `hermes model` |
| Dashboard: `ERR_CONNECTION_RESET` en el navegador | Escucha solo en loopback del contenedor | `socat` + puerto publicado en `127.0.0.1` (sección 5) |
| Dockerfile: `unknown instruction: echo` | Se editó el archivo insertando líneas en medio de otro bloque | Recrear el archivo completo: `rm` + `cat > ... << 'EOF'` |
| Gatekeeper bloquea un `.pkg` | Marca de cuarentena del navegador | Descargar con `curl` |
| `curl` a una URL con `latest` devuelve 9 bytes | La URL no apunta a un archivo | Obtener la URL exacta desde la API de GitHub |
| Log: `socat ... Connection refused` al arrancar | `socat` arranca segundos antes que el dashboard | Inofensivo; las conexiones siguientes funcionan |
| Log: `this process is PID 1 with no init` | Falta un proceso init | `init: true` en `docker-compose.yml` |
| Herdr: aparecen varios "spaces" vacíos | Se hizo clic varias veces en "New" | Ignorarlos o cerrar con clic derecho → *Close workspace* |

## 10. Reglas de oro

1. **Recrear archivos completos** con `rm archivo` y `cat > archivo << 'EOF'` en vez de editarlos a mano: evita errores de tipeo.
2. **Nunca subir `.env`**. Revisa `git status` antes de cada commit.
3. **`docker compose down -v` borra los datos.** Usa `stop` o `down` sin `-v`.
4. **Avanza por etapas** y confirma cada una antes de pasar a la siguiente.
5. **Pregunta a la herramienta**: los comandos cambian entre versiones. Usa `--help` en vez de adivinar nombres.
6. **Ante un fallo, mira primero los logs**: `docker logs hermes-agent`.
7. **Trabaja siempre dentro de `~/proyectos/hermes-infra`** al usar `docker compose`.

## 11. Pendientes

- Perfil `documentador`: instalar `gh` dentro del contenedor y compartir la autenticación del Mac montando `~/.config/gh` como volumen de solo lectura; luego crear el perfil con `hermes profile create documentador --clone --description "..."`.
- Agregar la API key de Anthropic cuando haya presupuesto.
- Evaluar despliegue en una VPS para disponibilidad 24/7.
- Proyecto de portafolio: aplicación web de delivery con verificación de edad.
