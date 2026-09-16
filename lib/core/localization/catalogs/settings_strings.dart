/// Settings and onboarding UI translations. Storage IDs are never translated.
const settingsTranslations = <String, Map<String, String>>{
  'es': {
    "Current {version}{latest}": "Actual {version}{latest}",
    "Anonymous crash reports start enabled on new installs and are optional. Existing installs keep their current choice. You can turn them off here or anytime in Settings. Reports contain only the app/build, error type and time, Android version, CPU architecture, device class, and a redacted technical trace. They never include a show, episode, account, device ID, source, or URL.":
        "Los informes anónimos de fallos comienzan activados en instalaciones nuevas y son opcionales. Las instalaciones existentes conservan su elección actual. Puedes desactivarlos aquí o en cualquier momento en Ajustes. Los informes contienen solo la app/build, el tipo y la hora del error, la versión de Android, la arquitectura de CPU, la clase de dispositivo y una traza técnica censurada. Nunca incluyen una serie, episodio, cuenta, ID de dispositivo, fuente o URL.",
    "The Beta live count shares only whether TetoTV is active or has an MPV player open. It contains no profile or media details; normal HTTPS delivery and short-lived abuse limits may process an IP address, but the presence record does not store it.":
        "El recuento beta solo comparte si TetoTV está activo o tiene un reproductor MPV abierto. No contiene perfiles ni datos multimedia; HTTPS y límites antiabuso temporales pueden procesar una IP, pero el registro de actividad no la guarda.",
    "Installed version: {version}{date}": "Versión instalada: {version}{date}",
    "Latest {channel}: {version}": "Última {channel}: {version}",
    "Latest {version}": "Última {version}",
    "Downloading {percent}%": "Descargando {percent}%",
    "Loading releases…": "Cargando versiones…",
    "Load release history": "Cargar historial de versiones",
    "Opening installer…": "Abriendo instalador…",
    "Install update": "Instalar actualización",
    "Check for updates": "Buscar actualizaciones",
    "Automatic: ON": "Automático: SÍ",
    "Automatic: OFF": "Automático: NO",
    "Apply theme": "Aplicar tema",
    "Theme applied.": "Tema aplicado.",
    "TetoTV colors restored.": "Colores de TetoTV restablecidos.",
    "Fix the contrast warnings or turn off the safeguard.":
        "Corrige los avisos de contraste o desactiva la protección.",
    "The readability safeguard blocked this theme.":
        "La protección de legibilidad bloqueó este tema.",
    "Trackers store whole completed episodes, so the selected percentage marks the current episode watched.":
        "Los trackers guardan episodios completos; el porcentaje seleccionado marca el actual como visto.",
    "Checking installed video players…":
        "Comprobando reproductores instalados…",
    "External apps can only receive safe, header-free streams. Private Plex and Jellyfin sessions stay in TetoTV.":
        "Las apps externas solo reciben streams seguros sin cabeceras. Las sesiones privadas de Plex y Jellyfin permanecen en TetoTV.",
    "Adds an Open externally action for compatible streams. Turning this off returns an external default to Media3; your built-in player choice stays selected. TetoTV never shares account headers or private-server credentials.":
        "Añade Abrir externamente para streams compatibles. Al desactivarlo, un reproductor externo predeterminado vuelve a Media3; el integrado elegido se conserva. TetoTV nunca comparte cabeceras de cuentas ni credenciales privadas.",
    "Reorder": "Reordenar",
    "English logo": "Logo en inglés",
    "Copy full report": "Copiar informe completo",
    "Export full report": "Exportar informe completo",
    "Full redacted report copied.": "Informe completo censurado copiado.",
    "Send diagnostic report?": "¿Enviar informe de diagnóstico?",
    "Send report": "Enviar informe",
    "The diagnostic report could not be sent. Try again shortly.":
        "No se pudo enviar el informe de diagnóstico. Inténtalo en breve.",
    "Support report": "Informe de soporte",
    "Recent redacted events": "Eventos recientes censurados",
    "Playback session timelines": "Cronología de sesiones de reproducción",
    "Started vs failed playback": "Reproducciones iniciadas y fallidas",
    "Started session": "Sesión iniciada",
    "Failed session": "Sesión fallida",
    "No recent playback or provider failures.":
        "No hay fallos recientes de reproducción o proveedores.",
    "No correlated playback sessions have been recorded yet.":
        "Aún no se han registrado sesiones de reproducción correlacionadas.",
    "A session that started and a failed session are needed before TetoTV can compare them. This is not a smooth-versus-stuttering comparison.":
        "TetoTV necesita una sesión iniciada y una fallida para compararlas. No compara reproducción fluida con entrecortada.",
    "Privacy-safe stages correlate source selection, stream opening, decoder choice, fallback attempts, and the final result. Media names, addresses, URLs, filenames, headers, and server IDs are never shown.":
        "Las etapas protegidas relacionan selección de fuente, apertura del stream, decodificador, alternativas y resultado. Nunca muestran nombres de contenido, direcciones, URL, archivos, cabeceras ni ID de servidores.",
    "Started means video parameters became available, not that playback was smooth. Decoder choice is a requested policy; the full report includes sampled engine performance when available. UI frame timings describe the app interface, not video frame rate or dropped video frames.":
        "Iniciada significa que hubo parámetros de vídeo, no que fuera fluido. El decodificador refleja la política solicitada; el informe completo incluye muestras de rendimiento cuando existen. Los tiempos de la interfaz no son los FPS ni los fotogramas perdidos del vídeo.",
    "A complete bounded dump of device capabilities, player health, performance timings, provider health, and the preceding 48 hours of persisted app events and crash summaries. Account identity, credentials, watch-room secrets, direct media sources, URLs, file paths, and network addresses are removed before it leaves the TV.":
        "Informe completo de tamaño limitado sobre capacidades del dispositivo, estado del reproductor y proveedores, rendimiento y eventos y fallos guardados de las últimas 48 horas. Antes de salir del TV se eliminan identidad, credenciales, secretos de salas, fuentes directas, URL, rutas y direcciones de red.",
    "This posts the complete bounded, redacted technical dump shown in Diagnostics to TetoTV’s private Discord support channel. It includes the app build, device capabilities, player and provider health, performance timings, and the preceding 48 hours of persisted events and crash summaries. Account identity, credentials, watch-room secrets, direct media sources, file paths, and network addresses are excluded.":
        "Esto envía el informe técnico completo, limitado y censurado de Diagnóstico al canal privado de soporte de Discord de TetoTV. Incluye versión, capacidades, estado del reproductor y proveedores, rendimiento y eventos y fallos guardados de las últimas 48 horas. Excluye identidad, credenciales, secretos de salas, fuentes directas, rutas y direcciones de red.",
    "Save recommendation": "Guardar recomendación",
    "Scan again": "Analizar de nuevo",
    "Video decoders": "Decodificadores de vídeo",
    "TetoTV scans Android’s decoders, display, audio output, and subtitle engine.":
        "TetoTV analiza los decodificadores, pantalla, salida de audio y motor de subtítulos de Android.",
    "The privacy disclosure could not be loaded.":
        "No se pudo cargar la información de privacidad.",
    "Third-party notices could not be loaded.":
        "No se pudieron cargar los avisos de terceros.",
    "Third-party notices document": "Documento de avisos de terceros",
    "This device does not support resetting TetoTV.":
        "Este dispositivo no admite restablecer TetoTV.",
    "This device does not support TetoTV cache cleanup.":
        "Este dispositivo no admite limpiar la caché de TetoTV.",
    "Direct torrent is unavailable": "Torrent directo no disponible",
    "This build supports direct torrent playback and downloads on ARM32 and ARM64 Android devices. It is unavailable on this device architecture.":
        "Esta versión permite torrents directos en dispositivos Android ARM32 y ARM64. No está disponible en la arquitectura de este dispositivo.",
    "Enable direct peer torrents?": "¿Activar torrents directos entre pares?",
    "Enable direct peers": "Activar pares directos",
    "Keep off": "Mantener desactivado",
    "This connects directly to public torrent peers without a debrid account. Your public IP address is visible to peers and trackers, and selected episode data may upload while you watch or download. Streaming may use up to 6 GB of temporary storage; offline files remain until you delete them in Download Manager. Only access content you are legally allowed to use.":
        "Esto conecta directamente con pares torrent públicos sin cuenta debrid. Tu IP pública es visible para pares y trackers, y se pueden subir datos del episodio mientras ves o descargas. Puede usar hasta 6 GB temporales; los archivos sin conexión permanecen hasta borrarlos en el gestor. Accede solo a contenido que puedas usar legalmente.",
    "Not installed — TetoTV will fall back to Media3":
        "No instalado: TetoTV usará Media3",
    "Offer installed video players for compatible, header-free streams.":
        "Ofrecer reproductores instalados para streams compatibles sin cabeceras.",
    "Open externally": "Abrir externamente",
    "Choose which buttons are shown and move them into your preferred order. Settings can move to the profile menu, with a top-row fallback on small screens or when no profile is linked.":
        "Elige los botones visibles y ordénalos. Ajustes puede moverse al menú de perfil, con acceso superior en pantallas pequeñas o sin perfil vinculado.",
    "Entries marked Blocked by Android remain visible for reference but cannot be selected. Android cannot replace this installation with a lower build code; Developer Mode cannot bypass that rule. A same-or-higher-code rebuild can roll back while preserving data.":
        "Las entradas Bloqueado por Android se muestran como referencia, pero no pueden elegirse. Android no permite instalar un código inferior; el modo desarrollador no lo evita. Una recompilación con código igual o superior permite volver atrás conservando datos.",
    "Join the TetoTV Discord for announcements, support, and feature requests.":
        "Únete al Discord de TetoTV para anuncios, soporte y sugerencias.",
    "Scan the code with your phone, or select the invite below to copy it.":
        "Escanea el código con tu teléfono o selecciona la invitación para copiarla.",
    "Donations are optional. Scan with your phone to open the official TetoTV Ko-fi page, or select the link below to copy it.":
        "Las donaciones son opcionales. Escanea con el teléfono para abrir Ko-fi oficial de TetoTV o selecciona el enlace para copiarlo.",
    "Optional. When enabled, Discord can show the anime title, episode, playing or paused state, and playback timer. TetoTV never asks for or stores your Discord password.":
        "Opcional. Discord puede mostrar título, episodio, estado de reproducción o pausa y temporizador. TetoTV nunca pide ni guarda tu contraseña de Discord.",
    "Development disclosure: TetoTV includes code created and reviewed with AI-assisted development tools. Releases are tested and maintained by the project owner.":
        "Desarrollo: TetoTV incluye código creado y revisado con herramientas asistidas por IA. El responsable del proyecto prueba y mantiene las versiones.",
    "TetoTV is an independent, unofficial client. It is not affiliated with or endorsed by AniList, MAL, Kitsu, SIMKL, debrid services, addon authors, or media rights holders. Users add and are responsible for their own services and repositories.":
        "TetoTV es un cliente independiente y no oficial. No está afiliado ni respaldado por AniList, MAL, Kitsu, SIMKL, servicios debrid, autores de complementos o titulares de derechos. Los usuarios añaden sus servicios y repositorios y son responsables de ellos.",
    "Reports may include the app version, Android version, device class, error type, time, and a redacted trace. They never include what you watch, accounts, device IDs, sources, or URLs.":
        "Los informes pueden incluir versiones de app y Android, tipo de dispositivo, error, hora y traza censurada. Nunca incluyen lo que ves, cuentas, ID de dispositivo, fuentes ni URL.",
    "Shares only whether this Beta app process is active or has an MPV player open. A paused or loading player can still count as watching. No profile, title, episode, source, device ID, URL, or media information is sent. HTTPS and abuse limits may process your IP, but it is not stored in the presence record.":
        "Solo comparte si la app beta está activa o tiene un reproductor MPV abierto. Pausa o carga pueden contar como reproducción. No envía perfil, título, episodio, fuente, ID de dispositivo, URL ni datos multimedia. HTTPS y los límites antiabuso pueden procesar tu IP, pero no se guarda en el registro de actividad.",
    "{step} of {count}": "{step} de {count}",
    "{count} selected": "{count} seleccionadas",
    "{count} sources added": "{count} fuentes añadidas",
    "Delete {name}?": "¿Eliminar {name}?",
    "Connected as {name}. Lists and episode progress sync automatically.":
        "Conectado como {name}. Las listas y el progreso se sincronizan automáticamente.",
    "Build: {number}": "Compilación: {number}",
    "Prefer dubbed sources. Track selection follows Preferred audio language.":
        "Priorizar fuentes dobladas. La pista sigue el idioma de audio preferido.",
    "Prefer subtitled sources. Track selection follows Preferred audio language.":
        "Priorizar fuentes subtituladas. La pista sigue el idioma de audio preferido.",
    "Preparing secure phone setup…":
        "Preparando configuración segura por teléfono…",
    "Secure setup resumed.": "Configuración segura reanudada.",
    "Finishing the setup already applied on this device…":
        "Terminando la configuración aplicada en este dispositivo…",
    "Scan the QR code or enter the code on your phone.":
        "Escanea el QR o introduce el código en tu teléfono.",
    "Secure phone setup could not start. Check the connection and try again.":
        "No pudo iniciarse la configuración segura. Comprueba la conexión y reintenta.",
    "Waiting for your phone to connect…":
        "Esperando la conexión de tu teléfono…",
    "Phone connected. Your progress is saved while you finish setup.":
        "Teléfono conectado. Tu progreso se guarda mientras terminas.",
    "The encrypted setup did not pass validation. Review it on your phone and send it again.":
        "La configuración cifrada no pasó la validación. Revísala en tu teléfono y envíala otra vez.",
    "Review what will be added. Account secrets remain hidden.":
        "Revisa lo que se añadirá. Los secretos de las cuentas siguen ocultos.",
    "Phone setup is complete.": "Configuración por teléfono completada.",
    "The phone rejected or could not finish this setup. Try again.":
        "El teléfono rechazó o no pudo terminar la configuración. Reintenta.",
    "Connection interrupted. TetoTV will keep trying securely in the background.":
        "Conexión interrumpida. TetoTV seguirá intentando de forma segura en segundo plano.",
    "Verifying accounts and applying your choices…":
        "Verificando cuentas y aplicando tus opciones…",
    "Your choices are saved. Reconnecting to confirm completion…":
        "Tus opciones están guardadas. Reconectando para confirmar…",
    "Setup could not be applied. Nothing was sent back; try again.":
        "No pudo aplicarse la configuración. No se envió nada; reintenta.",
    "Returning this setup to your phone for changes…":
        "Devolviendo la configuración al teléfono para cambios…",
    "Make your changes on the phone, then send them again.":
        "Haz los cambios en el teléfono y envíalos otra vez.",
    "Could not return the setup yet. Try again.":
        "Aún no pudo devolverse la configuración. Reintenta.",
    "Creating a fresh secure setup code…": "Creando un nuevo código seguro…",
    "Invalidating the old code before creating a new one…":
        "Invalidando el código anterior antes de crear otro…",
    "A new secure setup code is ready.":
        "Nuevo código de configuración segura listo.",
    "The old code could not be replaced securely. Check the connection and try again.":
        "No pudo reemplazarse el código de forma segura. Comprueba la conexión y reintenta.",
    "This setup session expired. Create a new secure code.":
        "Esta sesión caducó. Crea un nuevo código seguro.",
    "Protected with end-to-end encryption. You sign in only on each service's official page; TetoTV never asks for passwords. The setup companion holds the resulting credentials only temporarily, then your browser encrypts them for this device. Credentials never appear in the QR code, URL, browser draft storage, logs, or diagnostics. After your phone connects, the page can be minimized and reopened without losing the setup draft.":
        "Protegido con cifrado de extremo a extremo. Solo inicias sesión en la página oficial de cada servicio; TetoTV nunca pide contraseñas. El companion guarda las credenciales temporalmente y tu navegador las cifra para este dispositivo. Nunca aparecen en el QR, URL, borrador del navegador, registros ni diagnóstico. Tras conectar el teléfono, puedes minimizar y reabrir la página sin perder el borrador.",
    "Make TetoTV yours": "Haz TetoTV a tu medida",
    "Change the app canvas, panels, focus color and text. Your saved theme is shared by phone and TV layouts.":
        "Cambia el fondo, paneles, color de enfoque y texto. El tema guardado se comparte entre teléfono y TV.",
    "App colors": "Colores de la app",
    "Panels & surfaces": "Paneles y superficies",
    "Accent, focus & hover": "Acento, enfoque y cursor",
    "Primary text": "Texto principal",
    "Muted text": "Texto secundario",
    "App canvas and page backgrounds": "Fondo de la app y de las páginas",
    "Cards, menus and dialog panels": "Tarjetas, menús y diálogos",
    "Selection, focus rings and primary actions":
        "Selección, bordes de enfoque y acciones principales",
    "Headings and important labels": "Encabezados y etiquetas importantes",
    "Descriptions and secondary labels":
        "Descripciones y etiquetas secundarias",
    "Featured show": "Serie destacada",
    "Continue watching · Episode 7": "Seguir viendo · Episodio 7",
    "Your library": "Tu biblioteca",
    "Panels, labels and focus states update here.":
        "Los paneles, etiquetas y estados de enfoque se actualizan aquí.",
    "Focused": "Enfocado",
    "Protect readable contrast": "Proteger el contraste legible",
    "Prevents a theme from hiding text or TV focus rings.":
        "Evita que un tema oculte texto o bordes de enfoque de TV.",
    "Low-contrast theme allowed because the safeguard is off.":
        "Se permite el tema de bajo contraste porque la protección está desactivada.",
    "Choose a built-in color with the D-pad. Exact hex entry is available as an optional advanced choice.":
        "Elige un color integrado con el mando. Puedes introducir un valor hexadecimal como opción avanzada.",
    "Selected color": "Color seleccionado",
    "Built-in colors": "Colores integrados",
    "Built-in remote color picker": "Selector de colores con el mando",
    "Exact hex color": "Color hexadecimal exacto",
    "Use color": "Usar color",
    "Live theme preview": "Vista previa del tema",
    "Built-in": "Integrado",
    "Click": "Pulsación",
    "Display": "Pantalla",
    "Device": "Dispositivo",
    "App": "App",
    "Privacy": "Privacidad",
    "Home & navigation": "Inicio y navegación",
    "Home content": "Contenido de inicio",
    "Interface sounds": "Sonidos de la interfaz",
    "Featured": "Destacado",
    "First": "Primero",
    "Active": "Activo",
    "Optional": "Opcional",
    "Connected": "Conectado",
    "Not connected": "No conectado",
    "Linked": "Vinculado",
    "Not linked": "No vinculado",
    "Disabled": "Desactivado",
    "Unavailable": "No disponible",
    "Ready": "Listo",
    "Reconnect": "Reconectar",
    "Checking": "Comprobando",
    "Checking…": "Comprobando…",
    "Loading…": "Cargando…",
    "Saving…": "Guardando…",
    "Please wait…": "Espera…",
    "Manage": "Administrar",
    "Create": "Crear",
    "Save & verify": "Guardar y verificar",
    "Add profile": "Añadir perfil",
    "Shown": "Visible",
    "Hidden": "Oculto",
    "Discord account": "Cuenta de Discord",
    "Discord account linked": "Cuenta de Discord vinculada",
    "Checking Discord": "Comprobando Discord",
    "Unavailable on this device": "No disponible en este dispositivo",
    "Retry connection": "Reintentar conexión",
    "Disable Rich Presence": "Desactivar actividad de Discord",
    "Enable Rich Presence": "Activar actividad de Discord",
    "Authorize TetoTV through Discord’s secure account-linking flow.":
        "Autoriza TetoTV mediante la vinculación segura de Discord.",
    "Control whether your current playback appears on Discord.":
        "Controla si tu reproducción actual aparece en Discord.",
    "Turn Rich Presence back on for this linked account.":
        "Reactiva la actividad para esta cuenta vinculada.",
    "Connect SIMKL": "Conectar SIMKL",
    "Reconnect SIMKL": "Reconectar SIMKL",
    "Reconnect SIMKL to verify this saved account.":
        "Reconecta SIMKL para verificar esta cuenta guardada.",
    "Link SIMKL securely through its official sign-in page.":
        "Vincula SIMKL de forma segura desde su página oficial.",
    "SIMKL sign-in must be enabled on the TetoTV companion first.":
        "Primero debe activarse el acceso a SIMKL en el companion de TetoTV.",
    "Remove the saved SIMKL connection from TetoTV.":
        "Elimina la conexión guardada de SIMKL de TetoTV.",
    "Replace the saved connection through SIMKL’s secure sign-in.":
        "Reemplaza la conexión guardada mediante el acceso seguro de SIMKL.",
    "Open the secure SIMKL authorization flow.":
        "Abre la autorización segura de SIMKL.",
    "Clearing cache…": "Borrando caché…",
    "Clear cache": "Borrar caché",
    "Resetting TetoTV…": "Restableciendo TetoTV…",
    "Reset TetoTV": "Restablecer TetoTV",
    "Currently installed": "Instalado actualmente",
    "Same build number • package and signature checked before install":
        "Mismo número de compilación • paquete y firma verificados antes de instalar",
    "Older release • Android build compatibility checked before download":
        "Versión anterior • compatibilidad Android verificada antes de descargar",
    "Newer release • package and signature checked before install":
        "Versión nueva • paquete y firma verificados antes de instalar",
    "Not reported": "No informado",
    "Developer update tools": "Herramientas de actualización de desarrollador",
    "History enabled": "Historial activado",
    "Switch channels or inspect signed release history. Android only installs the same or a higher build code.":
        "Cambia canales o revisa versiones firmadas. Android solo instala códigos de compilación iguales o superiores.",
    "Choose Public or Beta. Beta builds may be less stable.":
        "Elige Pública o Beta. Las betas pueden ser menos estables.",
    "Secure updates ready": "Actualizaciones seguras listas",
    "What’s new": "Novedades",
    "Creating a secure session": "Creando una sesión segura",
    "Waiting for your phone": "Esperando a tu teléfono",
    "Phone connected": "Teléfono conectado",
    "Review before applying": "Revisa antes de aplicar",
    "Applying securely": "Aplicando de forma segura",
    "Setup complete": "Configuración completa",
    "Code expired": "Código caducado",
    "Setup unavailable": "Configuración no disponible",
    "Selected account": "Cuenta seleccionada",
    "Selected service": "Servicio seleccionado",
    "Preferences": "Preferencias",
    "Marketplace repositories": "Repositorios de Marketplace",
    "Torrent manifests": "Manifiestos torrent",
    "Debrid service": "Servicio debrid",
    "Authorized securely": "Autorizado de forma segura",
    "Connect after setup": "Conectar después de configurar",
    "Skip": "Omitir",
    "How would you like to set up TetoTV?": "¿Cómo quieres configurar TetoTV?",
    "Choose the setup method that works best for you.":
        "Elige el método de configuración que prefieras.",
    "You can adjust these choices later in Settings.":
        "Puedes cambiar estas opciones después en Ajustes.",
    "Preparing setup…": "Preparando configuración…",
    "First-run setup": "Configuración inicial",
    "Setup on device": "Configurar en este dispositivo",
    "Setup on another device": "Configurar en otro dispositivo",
    "Simple on-device setup": "Configuración sencilla en el dispositivo",
    "Phone-friendly setup": "Configuración desde el teléfono",
    "Simple D-pad setup": "Configuración sencilla con el mando",
    "Optimized for touch": "Optimizado para pantalla táctil",
    "Complete every setup step directly on this device.":
        "Completa toda la configuración en este dispositivo.",
    "Use a phone, tablet, or computer while this device stays on the setup screen.":
        "Usa un teléfono, tableta u ordenador mientras este dispositivo permanece en la pantalla de configuración.",
    "Leave setup?": "¿Salir de la configuración?",
    "You can finish these choices later from Settings.":
        "Puedes terminar estas opciones después en Ajustes.",
    "Keep setting up": "Seguir configurando",
    "Set up later": "Configurar más tarde",
    "Set up TetoTV": "Configurar TetoTV",
    "Choose your playback defaults": "Elige tus preferencias de reproducción",
    "Set your language, subtitles, input, and skipping.":
        "Configura idioma, subtítulos, entrada y saltos.",
    "Audio & subtitle default": "Audio y subtítulos predeterminados",
    "Anime title language": "Idioma de los títulos de anime",
    "Text input": "Entrada de texto",
    "TetoTV keyboard": "Teclado de TetoTV",
    "Device keyboard": "Teclado del dispositivo",
    "On-screen keyboard": "Teclado en pantalla",
    "Automatic skipping": "Saltos automáticos",
    "Skip intros": "Saltar intros",
    "Skip outros": "Saltar finales",
    "Connect your accounts": "Conecta tus cuentas",
    "Sync your watchlist and Discord presence, or skip either one.":
        "Sincroniza tu lista y actividad de Discord, u omite cualquiera.",
    "Anime list": "Lista de anime",
    "Connections are optional. TetoTV never sees or stores your account passwords.":
        "Las conexiones son opcionales. TetoTV nunca ve ni guarda tus contraseñas.",
    "Set up streaming": "Configurar streaming",
    "Connect providers and choose how episode sources are found.":
        "Conecta proveedores y elige cómo encontrar fuentes de episodios.",
    "Choose a debrid provider if you use one. Connecting it now is optional.":
        "Elige un proveedor debrid si lo usas. Conectarlo ahora es opcional.",
    "Your sources": "Tus fuentes",
    "Add only repositories and manifests you trust and are authorized to use. TetoTV does not bundle or recommend sources.":
        "Añade solo repositorios y manifiestos de confianza que tengas autorización para usar. TetoTV no incluye ni recomienda fuentes.",
    "Add sources with phone": "Añadir fuentes con el teléfono",
    "Open Marketplace manually": "Abrir Marketplace manualmente",
    "One last choice": "Una última opción",
    "Allow error reports": "Permitir informes de errores",
    "Do not send": "No enviar",
    "Anonymous crash and error reports":
        "Informes anónimos de fallos y errores",
    "Anonymous Beta live count": "Recuento activo anónimo de la beta",
    "Count me in": "Incluirme",
    "Opt out": "No participar",
    "Set up with phone": "Configurar con el teléfono",
    "One secure setup for accounts, Discord, sources, debrid, and preferences":
        "Una configuración segura para cuentas, Discord, fuentes, debrid y preferencias",
    "Connect your phone": "Conecta tu teléfono",
    "Open secure setup page": "Abrir página de configuración segura",
    "Match this on both screens": "Comprueba que coincide en ambas pantallas",
    "Edit on phone": "Editar en el teléfono",
    "Apply setup": "Aplicar configuración",
    "Start TetoTV": "Iniciar TetoTV",
    "Regenerate code": "Generar nuevo código",
    "Set up on this device instead": "Configurar en este dispositivo",
    "Use on-device setup instead": "Usar configuración en el dispositivo",
    "No browser could open the secure setup page.":
        "Ningún navegador pudo abrir la página de configuración segura.",
    "Account credentials are end-to-end encrypted and intentionally hidden from this preview. Linked services use their official authorization pages; passwords are never included.":
        "Las credenciales tienen cifrado de extremo a extremo y se ocultan en esta vista. Los servicios usan sus páginas oficiales de autorización; nunca se incluyen contraseñas.",
    "Anime tracking connected": "Seguimiento de anime conectado",
    "Discord connected": "Discord conectado",
    "Debrid service connected": "Servicio debrid conectado",
    "Encrypted setup verified": "Configuración cifrada verificada",
    "Preferences saved": "Preferencias guardadas",
    "Navigation & logo size": "Tamaño de navegación y logo",
    "Navigation bar": "Barra de navegación",
    "Home layout": "Diseño de inicio",
    "Home details": "Detalles de inicio",
    "Poster badges": "Insignias de póster",
    "Finish": "Finalizar",
    "Choose how Home looks and keep your everyday shortcuts close.":
        "Elige el aspecto de Inicio y mantén cerca tus accesos habituales.",
    "Modern Layout": "Diseño moderno",
    "Classic Layout (retired)": "Diseño clásico (retirado)",
    "After 50%": "Tras el 50 %",
    "After 75%": "Tras el 75 %",
    "After 90%": "Tras el 90 %",
    "At episode end": "Al terminar el episodio",
    "Mark the episode watched once half of it has played.":
        "Marcar visto al reproducir la mitad del episodio.",
    "Mark the episode watched after three quarters has played.":
        "Marcar visto al reproducir tres cuartas partes.",
    "Mark the episode watched near the end (recommended).":
        "Marcar visto cerca del final (recomendado).",
    "Only mark the episode watched after playback finishes.":
        "Marcar visto solo al terminar la reproducción.",
    "Use the preferred language when captions are needed.":
        "Usar el idioma preferido cuando hagan falta subtítulos.",
    "Start captions on when a matching track is available.":
        "Activar subtítulos al iniciar si hay una pista del idioma preferido.",
    "Start playback with captions off.":
        "Iniciar la reproducción sin subtítulos.",
    "Any": "Cualquiera",
    "Debrid only": "Solo debrid",
    "Web only": "Solo web",
    "Use the preferred source order": "Usar el orden de fuentes preferido",
    "Automatically select cached releases":
        "Seleccionar versiones en caché automáticamente",
    "Automatically select Web streams":
        "Seleccionar streams web automáticamente",
    "Local library": "Biblioteca local",
    "Cached torrent and debrid releases": "Versiones torrent y debrid en caché",
    "Marketplace Web streams": "Streams web del Marketplace",
    "Exact episode matches from local, Jellyfin, or Plex libraries":
        "Coincidencias exactas de episodios de bibliotecas locales, Jellyfin o Plex",
    "Allow every available resolution": "Permitir todas las resoluciones",
    "Dub only": "Solo doblaje",
    "Sub only": "Solo subtítulos",
    "Allow dubbed or subtitled streams":
        "Permitir streams doblados o subtitulados",
    "Require English audio support":
        "Exigir compatibilidad con audio en inglés",
    "Require original audio support":
        "Exigir compatibilidad con audio original",
    "TetoTV built-in player": "Reproductor integrado de TetoTV",
    "Built-in Android player with TetoTV controls":
        "Reproductor Android integrado con controles de TetoTV",
    "A selected app installed on this device":
        "Una app seleccionada instalada en este dispositivo",
    "Personalize TetoTV, the Home screen, navigation, and feedback.":
        "Personaliza TetoTV, Inicio, la navegación y los sonidos.",
    "Customize colors and preview the TetoTV interface.":
        "Personaliza colores y previsualiza la interfaz de TetoTV.",
    "Choose what appears on Home and move favorites toward the top.":
        "Elige qué aparece en Inicio y mueve tus favoritos arriba.",
    "Choose audio, skipping, seeking, and playback behavior.":
        "Configura audio, saltos, búsqueda y reproducción.",
    "Tune captions, player behavior, audio, skipping, and seeking.":
        "Ajusta subtítulos, reproductor, audio, saltos y búsqueda.",
    "Style subtitles for comfortable viewing on every screen.":
        "Adapta los subtítulos para leerlos cómodamente en cualquier pantalla.",
    "Compatibility engine with full TetoTV controls":
        "Motor de compatibilidad con todos los controles de TetoTV",
    "Default Android engine with the same TetoTV controls":
        "Motor Android predeterminado con los mismos controles de TetoTV",
    "SurfaceView (default). Media3 only; applies to the next video.":
        "SurfaceView (predeterminado). Solo Media3; se aplica al siguiente vídeo.",
    "TextureView. Turn on to restore the default SurfaceView renderer and select Media3 for the next video.":
        "TextureView. Actívalo para restaurar SurfaceView como renderizador predeterminado y seleccionar Media3 para el siguiente vídeo.",
    "Skip detected opening segments automatically.":
        "Saltar automáticamente los segmentos de apertura detectados.",
    "Skip detected ending segments automatically.":
        "Saltar automáticamente los segmentos finales detectados.",
    "Mark episodes identified as anime-original filler.":
        "Marcar episodios identificados como relleno original del anime.",
    "Play feedback while moving between controls.":
        "Reproducir sonidos al moverse entre controles.",
    "Play confirmation feedback when selecting an option.":
        "Reproducir un sonido al seleccionar una opción.",
    "Show supporting text beneath posters and media cards.":
        "Mostrar texto adicional bajo pósteres y tarjetas.",
    "Choose and securely connect the provider used to resolve streams.":
        "Elige y conecta de forma segura el proveedor de streams.",
    "Choose which source types are searched and how results are ranked.":
        "Elige qué tipos de fuentes buscar y cómo ordenar los resultados.",
    "Use cached and resolved streams from your linked service.":
        "Usar streams en caché y resueltos por tu servicio conectado.",
    "Include streams supplied by installed web addons.":
        "Incluir streams de los complementos web instalados.",
    "Play torrent releases directly without a debrid service.":
        "Reproducir torrents directamente sin servicio debrid.",
    "Install, remove, and organize streaming addons.":
        "Instala, elimina y organiza complementos de streaming.",
    "Choose the highest-ranked playable source automatically.":
        "Elegir automáticamente la fuente reproducible mejor clasificada.",
    "Prioritize source type, quality, and audio when TetoTV chooses for you.":
        "Prioriza tipo de fuente, calidad y audio al seleccionar automáticamente.",
    "Preferences change ranking only. Other usable streams remain available for manual choice and automatic failover.":
        "Las preferencias solo cambian el orden. Otros streams utilizables siguen disponibles para elegir manualmente o como alternativa automática.",
    "TetoTV tries each source class from top to bottom.":
        "TetoTV prueba cada tipo de fuente de arriba abajo.",
    "The first available quality in this order is selected.":
        "Se elige la primera calidad disponible en este orden.",
    "Manage local libraries, Watch Party, and offline viewing.":
        "Administra bibliotecas locales, salas y reproducción sin conexión.",
    "Connect libraries and add local files that appear in the normal source picker.":
        "Conecta bibliotecas y añade archivos locales al selector habitual de fuentes.",
    "Review active jobs, saved episodes, and device storage.":
        "Revisa tareas activas, episodios guardados y almacenamiento.",
    "Control privacy-sensitive source and playback behavior.":
        "Controla el comportamiento de fuentes y reproducción que afecta a la privacidad.",
    "Profiles, anime tracking, notifications, and linked services.":
        "Perfiles, seguimiento de anime, notificaciones y servicios conectados.",
    "Connect a list provider and keep episode progress synchronized.":
        "Conecta un proveedor de listas y sincroniza el progreso de episodios.",
    "Sync Kitsu lists, episode progress, and status securely.":
        "Sincroniza de forma segura las listas, el progreso de episodios y los estados de Kitsu.",
    "Manage local viewers and their separate preferences.":
        "Administra espectadores locales y sus preferencias.",
    "Create, switch, or remove names stored locally on this device.":
        "Crea, cambia o elimina nombres guardados en este dispositivo.",
    "Names are stored only on this device and never include tracker credentials. The selected name is shared with Watch Party participants.":
        "Los nombres solo se guardan en este dispositivo y nunca incluyen credenciales. El nombre seleccionado se comparte con la sala de reproducción.",
    "This removes only the local profile name. Shared history, settings, and connected trackers stay saved.":
        "Esto solo elimina el nombre del perfil local. El historial compartido, los ajustes y los trackers conectados se conservan.",
    "Choose when progress syncs and which episode alerts appear.":
        "Elige cuándo sincronizar el progreso y qué avisos mostrar.",
    "Notify when a subtitled or simulcast episode reaches its normal airtime.":
        "Avisar cuando un episodio subtitulado o simultáneo llegue a su hora de emisión.",
    "Notify only when a dubbed episode has a verified release schedule.":
        "Avisar solo si un episodio doblado tiene un horario confirmado.",
    "Control the optional Discord activity shown while you watch.":
        "Controla la actividad opcional de Discord mientras ves contenido.",
    "Remove this Discord connection from TetoTV on this device.":
        "Elimina esta conexión de Discord de TetoTV en este dispositivo.",
    "Manage this device, updates, diagnostics, privacy, storage, and legal information.":
        "Administra dispositivo, actualizaciones, diagnóstico, privacidad, almacenamiento e información legal.",
    "Setup, device compatibility, calibration, and diagnostics.":
        "Configuración, compatibilidad, calibración y diagnóstico.",
    "Change setup method or reconnect your services.":
        "Cambia el método de configuración o reconecta servicios.",
    "Adjust display fit, input, and playback compatibility.":
        "Ajusta pantalla, entrada y compatibilidad de reproducción.",
    "Review system health and export troubleshooting details.":
        "Revisa el estado del sistema y exporta datos de diagnóstico.",
    "Stable public releases download directly to this device.":
        "Las versiones públicas estables se descargan directamente aquí.",
    "Download signed updates automatically when a newer build is available.":
        "Descargar actualizaciones firmadas automáticamente cuando haya una versión nueva.",
    "Check this channel and open Android’s installer when the package is ready.":
        "Comprueba este canal y abre el instalador de Android cuando esté listo.",
    "Fetch the signed release list for the selected update channel.":
        "Obtener la lista de versiones firmadas del canal seleccionado.",
    "Signed releases download securely from the official TetoTV repository.":
        "Las versiones firmadas se descargan de forma segura del repositorio oficial de TetoTV.",
    "Remove temporary files or return TetoTV to first-time setup.":
        "Elimina archivos temporales o restablece TetoTV a la configuración inicial.",
    "Remove temporary images, playback cache, and update leftovers. Accounts and settings stay saved.":
        "Elimina imágenes temporales, caché y restos de actualizaciones. Se conservan cuentas y ajustes.",
    "Erase accounts, preferences, sources, and history, then return to first-time setup.":
        "Borra cuentas, preferencias, fuentes e historial y vuelve a la configuración inicial.",
    "Privacy, attribution, and open-source notices.":
        "Privacidad, atribución y avisos de código abierto.",
    "Review what TetoTV stores, processes, and shares.":
        "Consulta qué guarda, procesa y comparte TetoTV.",
    "Read attribution and open-source license notices.":
        "Lee atribuciones y licencias de código abierto.",
    "Control optional privacy-safe reporting and Beta activity signals.":
        "Controla informes opcionales seguros y señales de actividad beta.",
    "Review the optional privacy controls used by this build.":
        "Revisa los controles opcionales de privacidad de esta versión.",
    "Send a redacted technical report after an unexpected crash.":
        "Envía un informe técnico censurado tras un fallo inesperado.",
    "Include this device in the privacy-safe Beta activity count.":
        "Incluye este dispositivo en el recuento anónimo de actividad beta.",
    "Validate and save this credential securely.":
        "Validar y guardar esta credencial de forma segura.",
    "Open the secure device authorization flow.":
        "Abrir la autorización segura del dispositivo.",
    "Open TorBox device authorization.":
        "Abrir autorización de dispositivo TorBox.",
    "Remove the saved Real-Debrid connection.":
        "Eliminar la conexión de Real-Debrid guardada.",
    "Remove the saved TorBox connection.":
        "Eliminar la conexión de TorBox guardada.",
    "Choose your language": "Elige tu idioma",
    "This sets the app language and preferred audio and captions. You can change them separately later.":
        "Esto configura el idioma de la app, el audio y los subtítulos preferidos. Puedes cambiarlos por separado después.",
    "Also sets preferred audio and captions. You can change them separately in Playback.":
        "También configura el audio y los subtítulos preferidos. Puedes cambiarlos por separado en Reproducción.",
    "App language": "Idioma de la app",
    "Appearance": "Apariencia",
    "Playback": "Reproducción",
    "Services": "Servicios",
    "Accounts": "Cuentas",
    "System": "Sistema",
    "Settings": "Ajustes",
    "Theme & display": "Tema y pantalla",
    "Theme Studio": "Estudio de temas",
    "Title language": "Idioma de los títulos",
    "Show title style": "Estilo del título",
    "Colors": "Colores",
    "Home screen": "Pantalla de inicio",
    "Featured hero": "Destacado principal",
    "Poster metadata": "Datos del póster",
    "Continue watching": "Seguir viendo",
    "Display options": "Opciones de pantalla",
    "Interface scale": "Escala de la interfaz",
    "Content density": "Densidad del contenido",
    "Thumbnail size": "Tamaño de miniaturas",
    "Layout style": "Estilo de diseño",
    "Default landing page": "Página de inicio predeterminada",
    "Card details": "Detalles de tarjetas",
    "Input & feedback": "Entrada y respuesta",
    "Home shelves": "Secciones de inicio",
    "Navigation": "Navegación",
    "Navigation size": "Tamaño de navegación",
    "Menu order": "Orden del menú",
    "Navigation sounds": "Sonidos de navegación",
    "Click sounds": "Sonidos al pulsar",
    "Closed captions": "Subtítulos",
    "Player controls": "Controles del reproductor",
    "Debrid streaming": "Streaming debrid",
    "Sources & stream order": "Fuentes y orden de streams",
    "Automatic source selection": "Selección automática de fuentes",
    "Libraries & features": "Bibliotecas y funciones",
    "Streaming privacy": "Privacidad del streaming",
    "Anime tracking": "Seguimiento de anime",
    "Profiles": "Perfiles",
    "Progress & notifications": "Progreso y notificaciones",
    "Discord Rich Presence": "Actividad en Discord",
    "Device & support": "Dispositivo y soporte",
    "App updates": "Actualizaciones de la app",
    "Community": "Comunidad",
    "Storage & reset": "Almacenamiento y restablecimiento",
    "About & legal": "Información y aspectos legales",
    "Privacy & diagnostics": "Privacidad y diagnóstico",
    "Search settings": "Buscar ajustes",
    "No matching settings": "Sin ajustes coincidentes",
    "No matching settings found": "No se encontraron ajustes",
    "Expand all": "Expandir todo",
    "Collapse all": "Contraer todo",
    "Back": "Atrás",
    "Close": "Cerrar",
    "Continue": "Continuar",
    "Cancel": "Cancelar",
    "Delete": "Eliminar",
    "Save": "Guardar",
    "Use": "Usar",
    "OK": "Aceptar",
    "Try again": "Reintentar",
    "Refresh": "Actualizar",
    "Reset defaults": "Restablecer valores",
    "On": "Activado",
    "Off": "Desactivado",
    "Automatic": "Automático",
    "Small": "Pequeño",
    "Medium": "Mediano",
    "Large": "Grande",
    "Compact": "Compacto",
    "Standard": "Estándar",
    "Comfortable": "Espacioso",
    "Cinematic": "Cinematográfico",
    "Home": "Inicio",
    "Search": "Buscar",
    "My List": "Mi lista",
    "Discover": "Descubrir",
    "Calendar": "Calendario",
    "Watch Party": "Sala de reproducción",
    "Downloads": "Descargas",
    "Play": "Reproducir",
    "Text title": "Título en texto",
    "Title logo": "Logo del título",
    "Top row": "Fila superior",
    "Profile menu": "Menú del perfil",
    "Local profiles": "Perfiles locales",
    "New local profile": "Nuevo perfil local",
    "Display name": "Nombre visible",
    "No local profiles yet.": "Aún no hay perfiles locales.",
    "Select to enter a name": "Selecciona para escribir un nombre",
    "Select to open the TV keyboard": "Selecciona para abrir el teclado de TV",
    "Default player": "Reproductor predeterminado",
    "Preferred audio": "Audio preferido",
    "Preferred audio language": "Idioma de audio preferido",
    "Preferred CC": "Subtítulos preferidos",
    "Preferred subtitle language": "Idioma de subtítulos preferido",
    "Follow Dub/Sub": "Seguir doblaje/subtítulos",
    "English for Dubbed, Japanese for Subtitled":
        "Inglés para doblaje, japonés para subtítulos",
    "Media3 (Built in)": "Media3 (Integrado)",
    "MPV (Built in)": "MPV (Integrado)",
    "Media3 SurfaceView": "Media3 SurfaceView",
    "External player": "Reproductor externo",
    "Auto-skip intros": "Saltar intros automáticamente",
    "Auto-skip outros": "Saltar finales automáticamente",
    "Rewind": "Retroceder",
    "Fast-forward": "Avanzar",
    "Text color": "Color del texto",
    "Background": "Fondo",
    "Text size": "Tamaño del texto",
    "Filler episode labels": "Etiquetas de episodios de relleno",
    "Debrid provider": "Proveedor debrid",
    "Debrid streams": "Streams debrid",
    "Web streams": "Streams web",
    "Direct peer streaming": "Streaming directo entre pares",
    "Manage sources": "Administrar fuentes",
    "Debrid results": "Resultados debrid",
    "Source priority": "Prioridad de fuentes",
    "Quality priority": "Prioridad de calidad",
    "Preferred Web quality": "Calidad web preferida",
    "Automatic selection": "Selección automática",
    "Strict audio": "Filtro estricto de audio",
    "Local, Jellyfin & Plex sources": "Fuentes locales, Jellyfin y Plex",
    "Offline downloads": "Descargas sin conexión",
    "Download manager": "Gestor de descargas",
    "Anime-list provider": "Proveedor de lista de anime",
    "When to update episode progress": "Cuándo actualizar el progreso",
    "Sub & simulcast alerts": "Avisos de subtítulos y emisión simultánea",
    "Verified dub alerts": "Avisos de doblajes confirmados",
    "Discord presence": "Actividad en Discord",
    "Disconnect": "Desconectar",
    "Connect Discord": "Conectar Discord",
    "Unlink Discord": "Desvincular Discord",
    "Connect by QR": "Conectar por QR",
    "Personal API token": "Token API personal",
    "Personal API key": "Clave API personal",
    "Personal Access Token": "Token de acceso personal",
    "Manual API token": "Token API manual",
    "TorBox API token": "Token API de TorBox",
    "Run setup again": "Repetir configuración",
    "Device calibration": "Calibración del dispositivo",
    "Diagnostics": "Diagnóstico",
    "Update channel": "Canal de actualizaciones",
    "Release history": "Historial de versiones",
    "Check now": "Comprobar ahora",
    "Choose a compatible signed release":
        "Elige una versión firmada compatible",
    "Privacy & data": "Privacidad y datos",
    "Third-party notices": "Avisos de terceros",
    "Anonymous crash reports": "Informes de fallos anónimos",
    "Anonymous live count": "Recuento activo anónimo",
    "Reset appearance and navigation": "Restablecer apariencia y navegación",
    "Reset appearance & navigation": "Restablecer apariencia y navegación",
    "Reset all TetoTV data?": "¿Borrar todos los datos de TetoTV?",
    "Erase everything": "Borrar todo",
    "Keep my data": "Conservar mis datos",
    "Cancel reset": "Cancelar restablecimiento",
    "Final confirmation": "Confirmación final",
    "Support TetoTV": "Apoyar TetoTV",
    "Join the TetoTV Discord": "Únete al Discord de TetoTV",
    "Copy Discord invite": "Copiar invitación de Discord",
    "Discord invite copied.": "Invitación de Discord copiada.",
    "Copy Ko-fi link": "Copiar enlace de Ko-fi",
    "Ko-fi donation link copied.": "Enlace de donación de Ko-fi copiado.",
  },
  'pt': {
    "Current {version}{latest}": "Atual {version}{latest}",
    "Anonymous crash reports start enabled on new installs and are optional. Existing installs keep their current choice. You can turn them off here or anytime in Settings. Reports contain only the app/build, error type and time, Android version, CPU architecture, device class, and a redacted technical trace. They never include a show, episode, account, device ID, source, or URL.":
        "Os relatórios anônimos de falhas começam ativados em instalações novas e são opcionais. Instalações existentes mantêm a escolha atual. Você pode desativá-los aqui ou a qualquer momento em Configurações. Os relatórios contêm apenas app/build, tipo e horário do erro, versão do Android, arquitetura da CPU, classe do dispositivo e um rastreamento técnico anonimizado. Nunca incluem série, episódio, conta, ID do dispositivo, fonte ou URL.",
    "The Beta live count shares only whether TetoTV is active or has an MPV player open. It contains no profile or media details; normal HTTPS delivery and short-lived abuse limits may process an IP address, but the presence record does not store it.":
        "A contagem Beta só compartilha se o TetoTV está ativo ou tem um player MPV aberto. Não contém perfis nem dados de mídia; HTTPS e limites antiabuso temporários podem processar um IP, mas o registro de atividade não o salva.",
    "Installed version: {version}{date}": "Versão instalada: {version}{date}",
    "Latest {channel}: {version}": "Última {channel}: {version}",
    "Latest {version}": "Última {version}",
    "Downloading {percent}%": "Baixando {percent}%",
    "Loading releases…": "Carregando versões…",
    "Load release history": "Carregar histórico de versões",
    "Opening installer…": "Abrindo instalador…",
    "Install update": "Instalar atualização",
    "Check for updates": "Verificar atualizações",
    "Automatic: ON": "Automático: ATIVADO",
    "Automatic: OFF": "Automático: DESATIVADO",
    "Apply theme": "Aplicar tema",
    "Theme applied.": "Tema aplicado.",
    "TetoTV colors restored.": "Cores do TetoTV restauradas.",
    "Fix the contrast warnings or turn off the safeguard.":
        "Corrija os avisos de contraste ou desative a proteção.",
    "The readability safeguard blocked this theme.":
        "A proteção de legibilidade bloqueou este tema.",
    "Trackers store whole completed episodes, so the selected percentage marks the current episode watched.":
        "Rastreadores salvam episódios completos; a porcentagem selecionada marca o atual como assistido.",
    "Checking installed video players…": "Verificando players instalados…",
    "External apps can only receive safe, header-free streams. Private Plex and Jellyfin sessions stay in TetoTV.":
        "Apps externos só recebem streams seguros sem cabeçalhos. Sessões privadas do Plex e Jellyfin ficam no TetoTV.",
    "Adds an Open externally action for compatible streams. Turning this off returns an external default to Media3; your built-in player choice stays selected. TetoTV never shares account headers or private-server credentials.":
        "Adiciona Abrir externamente a streams compatíveis. Ao desativar, um padrão externo volta ao Media3; o player integrado escolhido é mantido. O TetoTV nunca compartilha cabeçalhos de contas ou credenciais privadas.",
    "Reorder": "Reordenar",
    "English logo": "Logo em inglês",
    "Copy full report": "Copiar relatório completo",
    "Export full report": "Exportar relatório completo",
    "Full redacted report copied.": "Relatório completo anonimizado copiado.",
    "Send diagnostic report?": "Enviar relatório de diagnóstico?",
    "Send report": "Enviar relatório",
    "The diagnostic report could not be sent. Try again shortly.":
        "Não foi possível enviar o relatório de diagnóstico. Tente em instantes.",
    "Support report": "Relatório de suporte",
    "Recent redacted events": "Eventos recentes anonimizados",
    "Playback session timelines": "Cronologia das sessões de reprodução",
    "Started vs failed playback": "Reproduções iniciadas e com falha",
    "Started session": "Sessão iniciada",
    "Failed session": "Sessão com falha",
    "No recent playback or provider failures.":
        "Nenhuma falha recente de reprodução ou provedores.",
    "No correlated playback sessions have been recorded yet.":
        "Ainda não há sessões de reprodução correlacionadas registradas.",
    "A session that started and a failed session are needed before TetoTV can compare them. This is not a smooth-versus-stuttering comparison.":
        "O TetoTV precisa de uma sessão iniciada e outra com falha para compará-las. Não é uma comparação entre reprodução fluida e travada.",
    "Privacy-safe stages correlate source selection, stream opening, decoder choice, fallback attempts, and the final result. Media names, addresses, URLs, filenames, headers, and server IDs are never shown.":
        "As etapas protegidas relacionam fonte, abertura do stream, decodificador, tentativas alternativas e resultado. Nomes de mídia, endereços, URLs, arquivos, cabeçalhos e IDs de servidor nunca são mostrados.",
    "Started means video parameters became available, not that playback was smooth. Decoder choice is a requested policy; the full report includes sampled engine performance when available. UI frame timings describe the app interface, not video frame rate or dropped video frames.":
        "Iniciada significa que havia parâmetros de vídeo, não que a reprodução foi fluida. O decodificador é a política solicitada; o relatório completo inclui amostras de desempenho quando disponíveis. Tempos da interface não são FPS nem quadros perdidos do vídeo.",
    "A complete bounded dump of device capabilities, player health, performance timings, provider health, and the preceding 48 hours of persisted app events and crash summaries. Account identity, credentials, watch-room secrets, direct media sources, URLs, file paths, and network addresses are removed before it leaves the TV.":
        "Relatório completo de tamanho limitado sobre dispositivo, player, desempenho, provedores e eventos e falhas salvos nas últimas 48 horas. Identidade, credenciais, segredos de salas, fontes diretas, URLs, caminhos e endereços de rede são removidos antes de sair da TV.",
    "This posts the complete bounded, redacted technical dump shown in Diagnostics to TetoTV’s private Discord support channel. It includes the app build, device capabilities, player and provider health, performance timings, and the preceding 48 hours of persisted events and crash summaries. Account identity, credentials, watch-room secrets, direct media sources, file paths, and network addresses are excluded.":
        "Isso envia o relatório técnico completo, limitado e anonimizado do Diagnóstico ao canal privado de suporte do TetoTV no Discord. Inclui versão, capacidades, estado do player e provedores, desempenho e eventos e falhas das últimas 48 horas. Exclui identidade, credenciais, segredos de salas, fontes diretas, caminhos e endereços de rede.",
    "Save recommendation": "Salvar recomendação",
    "Scan again": "Analisar novamente",
    "Video decoders": "Decodificadores de vídeo",
    "TetoTV scans Android’s decoders, display, audio output, and subtitle engine.":
        "O TetoTV analisa decodificadores, tela, saída de áudio e mecanismo de legendas do Android.",
    "The privacy disclosure could not be loaded.":
        "Não foi possível carregar a política de privacidade.",
    "Third-party notices could not be loaded.":
        "Não foi possível carregar os avisos de terceiros.",
    "Third-party notices document": "Documento de avisos de terceiros",
    "This device does not support resetting TetoTV.":
        "Este dispositivo não permite redefinir o TetoTV.",
    "This device does not support TetoTV cache cleanup.":
        "Este dispositivo não permite limpar o cache do TetoTV.",
    "Direct torrent is unavailable": "Torrent direto indisponível",
    "This build supports direct torrent playback and downloads on ARM32 and ARM64 Android devices. It is unavailable on this device architecture.":
        "Esta versão oferece torrents diretos em dispositivos Android ARM32 e ARM64. Não está disponível nesta arquitetura.",
    "Enable direct peer torrents?": "Ativar torrents diretos entre pares?",
    "Enable direct peers": "Ativar pares diretos",
    "Keep off": "Manter desativado",
    "This connects directly to public torrent peers without a debrid account. Your public IP address is visible to peers and trackers, and selected episode data may upload while you watch or download. Streaming may use up to 6 GB of temporary storage; offline files remain until you delete them in Download Manager. Only access content you are legally allowed to use.":
        "Isso conecta diretamente a pares torrent públicos sem conta debrid. Seu IP público fica visível a pares e trackers, e dados do episódio podem ser enviados enquanto assiste ou baixa. Pode usar até 6 GB temporários; arquivos offline ficam até serem excluídos no gerenciador. Acesse apenas conteúdo que você pode usar legalmente.",
    "Not installed — TetoTV will fall back to Media3":
        "Não instalado: o TetoTV usará Media3",
    "Offer installed video players for compatible, header-free streams.":
        "Oferecer players instalados para streams compatíveis sem cabeçalhos.",
    "Open externally": "Abrir externamente",
    "Choose which buttons are shown and move them into your preferred order. Settings can move to the profile menu, with a top-row fallback on small screens or when no profile is linked.":
        "Escolha os botões visíveis e a ordem. Configurações pode ir ao menu do perfil, com acesso superior em telas pequenas ou sem perfil vinculado.",
    "Entries marked Blocked by Android remain visible for reference but cannot be selected. Android cannot replace this installation with a lower build code; Developer Mode cannot bypass that rule. A same-or-higher-code rebuild can roll back while preserving data.":
        "Entradas Bloqueado pelo Android ficam visíveis, mas não podem ser escolhidas. O Android não instala um código menor; o modo desenvolvedor não evita essa regra. Uma recompilação com código igual ou maior permite voltar mantendo os dados.",
    "Join the TetoTV Discord for announcements, support, and feature requests.":
        "Entre no Discord do TetoTV para anúncios, suporte e sugestões.",
    "Scan the code with your phone, or select the invite below to copy it.":
        "Escaneie o código com o celular ou selecione o convite para copiá-lo.",
    "Donations are optional. Scan with your phone to open the official TetoTV Ko-fi page, or select the link below to copy it.":
        "Doações são opcionais. Escaneie com o celular para abrir o Ko-fi oficial do TetoTV ou selecione o link para copiá-lo.",
    "Optional. When enabled, Discord can show the anime title, episode, playing or paused state, and playback timer. TetoTV never asks for or stores your Discord password.":
        "Opcional. O Discord pode mostrar título, episódio, reprodução ou pausa e tempo. O TetoTV nunca pede nem armazena sua senha do Discord.",
    "Development disclosure: TetoTV includes code created and reviewed with AI-assisted development tools. Releases are tested and maintained by the project owner.":
        "Desenvolvimento: o TetoTV inclui código criado e revisado com ferramentas assistidas por IA. O responsável pelo projeto testa e mantém as versões.",
    "TetoTV is an independent, unofficial client. It is not affiliated with or endorsed by AniList, MAL, Kitsu, SIMKL, debrid services, addon authors, or media rights holders. Users add and are responsible for their own services and repositories.":
        "O TetoTV é um cliente independente e não oficial. Não tem vínculo nem endosso de AniList, MAL, Kitsu, SIMKL, serviços debrid, autores de complementos ou titulares de direitos. Os usuários adicionam seus serviços e repositórios e são responsáveis por eles.",
    "Reports may include the app version, Android version, device class, error type, time, and a redacted trace. They never include what you watch, accounts, device IDs, sources, or URLs.":
        "Os relatórios podem incluir versões do app e Android, tipo de dispositivo, erro, horário e rastreamento anonimizado. Nunca incluem o que você assiste, contas, IDs de dispositivo, fontes ou URLs.",
    "Shares only whether this Beta app process is active or has an MPV player open. A paused or loading player can still count as watching. No profile, title, episode, source, device ID, URL, or media information is sent. HTTPS and abuse limits may process your IP, but it is not stored in the presence record.":
        "Compartilha apenas se o app Beta está ativo ou tem um player MPV aberto. Pausa ou carregamento podem contar como reprodução. Não envia perfil, título, episódio, fonte, ID de dispositivo, URL ou dados de mídia. HTTPS e limites antiabuso podem processar seu IP, mas ele não é salvo no registro de atividade.",
    "{step} of {count}": "{step} de {count}",
    "{count} selected": "{count} selecionadas",
    "{count} sources added": "{count} fontes adicionadas",
    "Delete {name}?": "Excluir {name}?",
    "Connected as {name}. Lists and episode progress sync automatically.":
        "Conectado como {name}. Listas e progresso sincronizam automaticamente.",
    "Build: {number}": "Compilação: {number}",
    "Prefer dubbed sources. Track selection follows Preferred audio language.":
        "Priorizar fontes dubladas. A faixa segue o idioma de áudio preferido.",
    "Prefer subtitled sources. Track selection follows Preferred audio language.":
        "Priorizar fontes legendadas. A faixa segue o idioma de áudio preferido.",
    "Preparing secure phone setup…":
        "Preparando configuração segura pelo celular…",
    "Secure setup resumed.": "Configuração segura retomada.",
    "Finishing the setup already applied on this device…":
        "Concluindo a configuração aplicada neste dispositivo…",
    "Scan the QR code or enter the code on your phone.":
        "Escaneie o QR ou digite o código no celular.",
    "Secure phone setup could not start. Check the connection and try again.":
        "Não foi possível iniciar a configuração segura. Verifique a conexão e tente novamente.",
    "Waiting for your phone to connect…": "Aguardando a conexão do celular…",
    "Phone connected. Your progress is saved while you finish setup.":
        "Celular conectado. Seu progresso é salvo enquanto conclui.",
    "The encrypted setup did not pass validation. Review it on your phone and send it again.":
        "A configuração criptografada não passou na validação. Revise no celular e envie novamente.",
    "Review what will be added. Account secrets remain hidden.":
        "Revise o que será adicionado. Os segredos das contas ficam ocultos.",
    "Phone setup is complete.": "Configuração pelo celular concluída.",
    "The phone rejected or could not finish this setup. Try again.":
        "O celular rejeitou ou não conseguiu concluir a configuração. Tente novamente.",
    "Connection interrupted. TetoTV will keep trying securely in the background.":
        "Conexão interrompida. O TetoTV continuará tentando com segurança em segundo plano.",
    "Verifying accounts and applying your choices…":
        "Verificando contas e aplicando suas escolhas…",
    "Your choices are saved. Reconnecting to confirm completion…":
        "Suas escolhas foram salvas. Reconectando para confirmar…",
    "Setup could not be applied. Nothing was sent back; try again.":
        "Não foi possível aplicar a configuração. Nada foi enviado; tente novamente.",
    "Returning this setup to your phone for changes…":
        "Devolvendo a configuração ao celular para alterações…",
    "Make your changes on the phone, then send them again.":
        "Faça as alterações no celular e envie novamente.",
    "Could not return the setup yet. Try again.":
        "Ainda não foi possível devolver a configuração. Tente novamente.",
    "Creating a fresh secure setup code…": "Criando um novo código seguro…",
    "Invalidating the old code before creating a new one…":
        "Invalidando o código anterior antes de criar outro…",
    "A new secure setup code is ready.":
        "Novo código de configuração segura pronto.",
    "The old code could not be replaced securely. Check the connection and try again.":
        "Não foi possível substituir o código com segurança. Verifique a conexão e tente novamente.",
    "This setup session expired. Create a new secure code.":
        "Esta sessão expirou. Crie um novo código seguro.",
    "Protected with end-to-end encryption. You sign in only on each service's official page; TetoTV never asks for passwords. The setup companion holds the resulting credentials only temporarily, then your browser encrypts them for this device. Credentials never appear in the QR code, URL, browser draft storage, logs, or diagnostics. After your phone connects, the page can be minimized and reopened without losing the setup draft.":
        "Protegido com criptografia de ponta a ponta. Você entra apenas na página oficial de cada serviço; o TetoTV nunca pede senhas. O companion guarda as credenciais temporariamente e o navegador as criptografa para este dispositivo. Elas nunca aparecem no QR, URL, rascunho do navegador, registros ou diagnóstico. Após conectar o celular, você pode minimizar e reabrir a página sem perder o rascunho.",
    "Make TetoTV yours": "Deixe o TetoTV com a sua cara",
    "Change the app canvas, panels, focus color and text. Your saved theme is shared by phone and TV layouts.":
        "Altere fundo, painéis, cor de foco e texto. O tema salvo é compartilhado entre celular e TV.",
    "App colors": "Cores do app",
    "Panels & surfaces": "Painéis e superfícies",
    "Accent, focus & hover": "Destaque, foco e cursor",
    "Primary text": "Texto principal",
    "Muted text": "Texto secundário",
    "App canvas and page backgrounds": "Fundo do app e das páginas",
    "Cards, menus and dialog panels": "Cartões, menus e diálogos",
    "Selection, focus rings and primary actions":
        "Seleção, contornos de foco e ações principais",
    "Headings and important labels": "Títulos e rótulos importantes",
    "Descriptions and secondary labels": "Descrições e rótulos secundários",
    "Featured show": "Série em destaque",
    "Continue watching · Episode 7": "Continuar assistindo · Episódio 7",
    "Your library": "Sua biblioteca",
    "Panels, labels and focus states update here.":
        "Painéis, rótulos e estados de foco são atualizados aqui.",
    "Focused": "Em foco",
    "Protect readable contrast": "Proteger contraste legível",
    "Prevents a theme from hiding text or TV focus rings.":
        "Evita que o tema esconda texto ou contornos de foco da TV.",
    "Low-contrast theme allowed because the safeguard is off.":
        "O tema de baixo contraste é permitido porque a proteção está desativada.",
    "Choose a built-in color with the D-pad. Exact hex entry is available as an optional advanced choice.":
        "Escolha uma cor integrada com o controle. A entrada hexadecimal é uma opção avançada.",
    "Selected color": "Cor selecionada",
    "Built-in colors": "Cores integradas",
    "Built-in remote color picker": "Seletor de cores com controle",
    "Exact hex color": "Cor hexadecimal exata",
    "Use color": "Usar cor",
    "Live theme preview": "Prévia do tema",
    "Built-in": "Integrado",
    "Click": "Clique",
    "Display": "Exibição",
    "Device": "Dispositivo",
    "App": "App",
    "Privacy": "Privacidade",
    "Home & navigation": "Início e navegação",
    "Home content": "Conteúdo inicial",
    "Interface sounds": "Sons da interface",
    "Featured": "Destaque",
    "First": "Primeiro",
    "Active": "Ativo",
    "Optional": "Opcional",
    "Connected": "Conectado",
    "Not connected": "Não conectado",
    "Linked": "Vinculado",
    "Not linked": "Não vinculado",
    "Disabled": "Desativado",
    "Unavailable": "Indisponível",
    "Ready": "Pronto",
    "Reconnect": "Reconectar",
    "Checking": "Verificando",
    "Checking…": "Verificando…",
    "Loading…": "Carregando…",
    "Saving…": "Salvando…",
    "Please wait…": "Aguarde…",
    "Manage": "Gerenciar",
    "Create": "Criar",
    "Save & verify": "Salvar e verificar",
    "Add profile": "Adicionar perfil",
    "Shown": "Visível",
    "Hidden": "Oculto",
    "Discord account": "Conta do Discord",
    "Discord account linked": "Conta do Discord vinculada",
    "Checking Discord": "Verificando Discord",
    "Unavailable on this device": "Indisponível neste dispositivo",
    "Retry connection": "Tentar conexão novamente",
    "Disable Rich Presence": "Desativar atividade do Discord",
    "Enable Rich Presence": "Ativar atividade do Discord",
    "Authorize TetoTV through Discord’s secure account-linking flow.":
        "Autorize o TetoTV pela vinculação segura do Discord.",
    "Control whether your current playback appears on Discord.":
        "Controle se a reprodução atual aparece no Discord.",
    "Turn Rich Presence back on for this linked account.":
        "Reative a atividade para esta conta vinculada.",
    "Connect SIMKL": "Conectar SIMKL",
    "Reconnect SIMKL": "Reconectar SIMKL",
    "Reconnect SIMKL to verify this saved account.":
        "Reconecte o SIMKL para verificar esta conta salva.",
    "Link SIMKL securely through its official sign-in page.":
        "Vincule o SIMKL com segurança pela página oficial.",
    "SIMKL sign-in must be enabled on the TetoTV companion first.":
        "O login SIMKL deve ser ativado primeiro no companion do TetoTV.",
    "Remove the saved SIMKL connection from TetoTV.":
        "Remova a conexão salva do SIMKL do TetoTV.",
    "Replace the saved connection through SIMKL’s secure sign-in.":
        "Substitua a conexão salva pelo login seguro do SIMKL.",
    "Open the secure SIMKL authorization flow.":
        "Abra a autorização segura do SIMKL.",
    "Clearing cache…": "Limpando cache…",
    "Clear cache": "Limpar cache",
    "Resetting TetoTV…": "Redefinindo TetoTV…",
    "Reset TetoTV": "Redefinir TetoTV",
    "Currently installed": "Instalado atualmente",
    "Same build number • package and signature checked before install":
        "Mesmo número de compilação • pacote e assinatura verificados antes de instalar",
    "Older release • Android build compatibility checked before download":
        "Versão anterior • compatibilidade Android verificada antes de baixar",
    "Newer release • package and signature checked before install":
        "Versão nova • pacote e assinatura verificados antes de instalar",
    "Not reported": "Não informado",
    "Developer update tools": "Ferramentas de atualização do desenvolvedor",
    "History enabled": "Histórico ativado",
    "Switch channels or inspect signed release history. Android only installs the same or a higher build code.":
        "Troque canais ou confira versões assinadas. O Android só instala códigos de compilação iguais ou maiores.",
    "Choose Public or Beta. Beta builds may be less stable.":
        "Escolha Pública ou Beta. Versões Beta podem ser menos estáveis.",
    "Secure updates ready": "Atualizações seguras prontas",
    "What’s new": "Novidades",
    "Creating a secure session": "Criando uma sessão segura",
    "Waiting for your phone": "Aguardando seu celular",
    "Phone connected": "Celular conectado",
    "Review before applying": "Revise antes de aplicar",
    "Applying securely": "Aplicando com segurança",
    "Setup complete": "Configuração concluída",
    "Code expired": "Código expirado",
    "Setup unavailable": "Configuração indisponível",
    "Selected account": "Conta selecionada",
    "Selected service": "Serviço selecionado",
    "Preferences": "Preferências",
    "Marketplace repositories": "Repositórios do Marketplace",
    "Torrent manifests": "Manifestos torrent",
    "Debrid service": "Serviço debrid",
    "Authorized securely": "Autorizado com segurança",
    "Connect after setup": "Conectar após configurar",
    "Skip": "Pular",
    "How would you like to set up TetoTV?":
        "Como você quer configurar o TetoTV?",
    "Choose the setup method that works best for you.":
        "Escolha o método de configuração que preferir.",
    "You can adjust these choices later in Settings.":
        "Você pode alterar essas opções depois em Configurações.",
    "Preparing setup…": "Preparando configuração…",
    "First-run setup": "Configuração inicial",
    "Setup on device": "Configurar neste dispositivo",
    "Setup on another device": "Configurar em outro dispositivo",
    "Simple on-device setup": "Configuração simples no dispositivo",
    "Phone-friendly setup": "Configuração pelo celular",
    "Simple D-pad setup": "Configuração simples com o controle",
    "Optimized for touch": "Otimizado para toque",
    "Complete every setup step directly on this device.":
        "Conclua toda a configuração neste dispositivo.",
    "Use a phone, tablet, or computer while this device stays on the setup screen.":
        "Use celular, tablet ou computador enquanto este dispositivo permanece na tela de configuração.",
    "Leave setup?": "Sair da configuração?",
    "You can finish these choices later from Settings.":
        "Você pode concluir essas opções depois em Configurações.",
    "Keep setting up": "Continuar configurando",
    "Set up later": "Configurar depois",
    "Set up TetoTV": "Configurar o TetoTV",
    "Choose your playback defaults": "Escolha os padrões de reprodução",
    "Set your language, subtitles, input, and skipping.":
        "Defina idioma, legendas, entrada e pulos.",
    "Audio & subtitle default": "Áudio e legendas padrão",
    "Anime title language": "Idioma dos títulos de anime",
    "Text input": "Entrada de texto",
    "TetoTV keyboard": "Teclado do TetoTV",
    "Device keyboard": "Teclado do dispositivo",
    "On-screen keyboard": "Teclado na tela",
    "Automatic skipping": "Pulos automáticos",
    "Skip intros": "Pular aberturas",
    "Skip outros": "Pular encerramentos",
    "Connect your accounts": "Conecte suas contas",
    "Sync your watchlist and Discord presence, or skip either one.":
        "Sincronize sua lista e atividade no Discord, ou pule qualquer uma.",
    "Anime list": "Lista de anime",
    "Connections are optional. TetoTV never sees or stores your account passwords.":
        "As conexões são opcionais. O TetoTV nunca vê nem armazena suas senhas.",
    "Set up streaming": "Configurar streaming",
    "Connect providers and choose how episode sources are found.":
        "Conecte provedores e escolha como encontrar fontes de episódios.",
    "Choose a debrid provider if you use one. Connecting it now is optional.":
        "Escolha um provedor debrid se usar um. Conectá-lo agora é opcional.",
    "Your sources": "Suas fontes",
    "Add only repositories and manifests you trust and are authorized to use. TetoTV does not bundle or recommend sources.":
        "Adicione apenas repositórios e manifestos confiáveis que você tenha autorização para usar. O TetoTV não inclui nem recomenda fontes.",
    "Add sources with phone": "Adicionar fontes pelo celular",
    "Open Marketplace manually": "Abrir Marketplace manualmente",
    "One last choice": "Uma última escolha",
    "Allow error reports": "Permitir relatórios de erros",
    "Do not send": "Não enviar",
    "Anonymous crash and error reports":
        "Relatórios anônimos de falhas e erros",
    "Anonymous Beta live count": "Contagem ativa anônima do Beta",
    "Count me in": "Incluir minha atividade",
    "Opt out": "Não participar",
    "Set up with phone": "Configurar pelo celular",
    "One secure setup for accounts, Discord, sources, debrid, and preferences":
        "Uma configuração segura para contas, Discord, fontes, debrid e preferências",
    "Connect your phone": "Conecte seu celular",
    "Open secure setup page": "Abrir página de configuração segura",
    "Match this on both screens": "Confirme que é igual nas duas telas",
    "Edit on phone": "Editar no celular",
    "Apply setup": "Aplicar configuração",
    "Start TetoTV": "Iniciar TetoTV",
    "Regenerate code": "Gerar novo código",
    "Set up on this device instead": "Configurar neste dispositivo",
    "Use on-device setup instead": "Usar configuração no dispositivo",
    "No browser could open the secure setup page.":
        "Nenhum navegador conseguiu abrir a página de configuração segura.",
    "Account credentials are end-to-end encrypted and intentionally hidden from this preview. Linked services use their official authorization pages; passwords are never included.":
        "As credenciais são criptografadas de ponta a ponta e ocultadas nesta prévia. Os serviços usam suas páginas oficiais de autorização; senhas nunca são incluídas.",
    "Anime tracking connected": "Acompanhamento de anime conectado",
    "Discord connected": "Discord conectado",
    "Debrid service connected": "Serviço debrid conectado",
    "Encrypted setup verified": "Configuração criptografada verificada",
    "Preferences saved": "Preferências salvas",
    "Navigation & logo size": "Tamanho da navegação e do logo",
    "Navigation bar": "Barra de navegação",
    "Home layout": "Layout inicial",
    "Home details": "Detalhes da tela inicial",
    "Poster badges": "Selos nos pôsteres",
    "Finish": "Concluir",
    "Choose how Home looks and keep your everyday shortcuts close.":
        "Escolha a aparência da tela inicial e mantenha seus atalhos por perto.",
    "Modern Layout": "Layout moderno",
    "Classic Layout (retired)": "Layout clássico (descontinuado)",
    "After 50%": "Após 50%",
    "After 75%": "Após 75%",
    "After 90%": "Após 90%",
    "At episode end": "Ao terminar o episódio",
    "Mark the episode watched once half of it has played.":
        "Marcar como assistido após reproduzir metade do episódio.",
    "Mark the episode watched after three quarters has played.":
        "Marcar como assistido após reproduzir três quartos.",
    "Mark the episode watched near the end (recommended).":
        "Marcar como assistido perto do fim (recomendado).",
    "Only mark the episode watched after playback finishes.":
        "Marcar como assistido somente ao terminar a reprodução.",
    "Use the preferred language when captions are needed.":
        "Usar o idioma preferido quando as legendas forem necessárias.",
    "Start captions on when a matching track is available.":
        "Iniciar com legendas se houver uma faixa no idioma preferido.",
    "Start playback with captions off.": "Iniciar a reprodução sem legendas.",
    "Any": "Qualquer",
    "Debrid only": "Somente debrid",
    "Web only": "Somente web",
    "Use the preferred source order": "Usar a ordem de fontes preferida",
    "Automatically select cached releases":
        "Selecionar versões em cache automaticamente",
    "Automatically select Web streams":
        "Selecionar streams web automaticamente",
    "Local library": "Biblioteca local",
    "Cached torrent and debrid releases": "Versões torrent e debrid em cache",
    "Marketplace Web streams": "Streams web do Marketplace",
    "Exact episode matches from local, Jellyfin, or Plex libraries":
        "Episódios correspondentes de bibliotecas locais, Jellyfin ou Plex",
    "Allow every available resolution": "Permitir todas as resoluções",
    "Dub only": "Somente dublado",
    "Sub only": "Somente legendado",
    "Allow dubbed or subtitled streams":
        "Permitir streams dublados ou legendados",
    "Require English audio support": "Exigir suporte a áudio em inglês",
    "Require original audio support": "Exigir suporte a áudio original",
    "TetoTV built-in player": "Player integrado do TetoTV",
    "Built-in Android player with TetoTV controls":
        "Player Android integrado com controles do TetoTV",
    "A selected app installed on this device":
        "Um app selecionado instalado neste dispositivo",
    "Personalize TetoTV, the Home screen, navigation, and feedback.":
        "Personalize o TetoTV, a tela inicial, a navegação e os sons.",
    "Customize colors and preview the TetoTV interface.":
        "Personalize as cores e visualize a interface do TetoTV.",
    "Choose what appears on Home and move favorites toward the top.":
        "Escolha o que aparece no início e mova seus favoritos para cima.",
    "Choose audio, skipping, seeking, and playback behavior.":
        "Configure áudio, pulos, avanço e reprodução.",
    "Tune captions, player behavior, audio, skipping, and seeking.":
        "Ajuste legendas, player, áudio, pulos e avanço.",
    "Style subtitles for comfortable viewing on every screen.":
        "Personalize as legendas para ler com conforto em qualquer tela.",
    "Compatibility engine with full TetoTV controls":
        "Mecanismo de compatibilidade com todos os controles do TetoTV",
    "Default Android engine with the same TetoTV controls":
        "Mecanismo Android padrão com os mesmos controles do TetoTV",
    "SurfaceView (default). Media3 only; applies to the next video.":
        "SurfaceView (padrão). Somente Media3; aplica-se ao próximo vídeo.",
    "TextureView. Turn on to restore the default SurfaceView renderer and select Media3 for the next video.":
        "TextureView. Ative para restaurar o SurfaceView como renderizador padrão e selecionar o Media3 para o próximo vídeo.",
    "Skip detected opening segments automatically.":
        "Pular automaticamente as aberturas detectadas.",
    "Skip detected ending segments automatically.":
        "Pular automaticamente os encerramentos detectados.",
    "Mark episodes identified as anime-original filler.":
        "Marcar episódios identificados como filler original do anime.",
    "Play feedback while moving between controls.":
        "Reproduzir sons ao navegar entre controles.",
    "Play confirmation feedback when selecting an option.":
        "Reproduzir um som ao selecionar uma opção.",
    "Show supporting text beneath posters and media cards.":
        "Mostrar texto adicional abaixo de pôsteres e cartões.",
    "Choose and securely connect the provider used to resolve streams.":
        "Escolha e conecte com segurança o provedor de streams.",
    "Choose which source types are searched and how results are ranked.":
        "Escolha quais fontes pesquisar e como ordenar os resultados.",
    "Use cached and resolved streams from your linked service.":
        "Usar streams em cache e resolvidos pelo serviço conectado.",
    "Include streams supplied by installed web addons.":
        "Incluir streams fornecidos pelos complementos web instalados.",
    "Play torrent releases directly without a debrid service.":
        "Reproduzir torrents diretamente sem serviço debrid.",
    "Install, remove, and organize streaming addons.":
        "Instale, remova e organize complementos de streaming.",
    "Choose the highest-ranked playable source automatically.":
        "Escolher automaticamente a melhor fonte reproduzível.",
    "Prioritize source type, quality, and audio when TetoTV chooses for you.":
        "Priorize o tipo de fonte, a qualidade e o áudio na seleção automática.",
    "Preferences change ranking only. Other usable streams remain available for manual choice and automatic failover.":
        "As preferências mudam apenas a ordem. Outros streams utilizáveis continuam disponíveis para escolha manual e troca automática em caso de falha.",
    "TetoTV tries each source class from top to bottom.":
        "O TetoTV tenta cada tipo de fonte de cima para baixo.",
    "The first available quality in this order is selected.":
        "A primeira qualidade disponível nessa ordem é selecionada.",
    "Manage local libraries, Watch Party, and offline viewing.":
        "Gerencie bibliotecas locais, salas e reprodução offline.",
    "Connect libraries and add local files that appear in the normal source picker.":
        "Conecte bibliotecas e adicione arquivos locais ao seletor normal de fontes.",
    "Review active jobs, saved episodes, and device storage.":
        "Confira tarefas ativas, episódios salvos e armazenamento.",
    "Control privacy-sensitive source and playback behavior.":
        "Controle o comportamento de fontes e reprodução que afeta a privacidade.",
    "Profiles, anime tracking, notifications, and linked services.":
        "Perfis, acompanhamento de anime, notificações e serviços conectados.",
    "Connect a list provider and keep episode progress synchronized.":
        "Conecte um provedor de listas e sincronize o progresso dos episódios.",
    "Sync Kitsu lists, episode progress, and status securely.":
        "Sincronize com segurança listas, progresso de episódios e status do Kitsu.",
    "Manage local viewers and their separate preferences.":
        "Gerencie espectadores locais e suas preferências.",
    "Create, switch, or remove names stored locally on this device.":
        "Crie, alterne ou remova nomes salvos neste dispositivo.",
    "Names are stored only on this device and never include tracker credentials. The selected name is shared with Watch Party participants.":
        "Os nomes são salvos apenas neste dispositivo e nunca incluem credenciais. O nome selecionado é compartilhado com participantes da sala.",
    "This removes only the local profile name. Shared history, settings, and connected trackers stay saved.":
        "Isso remove apenas o nome do perfil local. Histórico compartilhado, configurações e rastreadores conectados são mantidos.",
    "Choose when progress syncs and which episode alerts appear.":
        "Escolha quando sincronizar o progresso e quais alertas mostrar.",
    "Notify when a subtitled or simulcast episode reaches its normal airtime.":
        "Avisar quando um episódio legendado ou simulcast chegar ao horário de exibição.",
    "Notify only when a dubbed episode has a verified release schedule.":
        "Avisar somente se o episódio dublado tiver uma data confirmada.",
    "Control the optional Discord activity shown while you watch.":
        "Controle a atividade opcional no Discord enquanto assiste.",
    "Remove this Discord connection from TetoTV on this device.":
        "Remova esta conexão do Discord do TetoTV neste dispositivo.",
    "Manage this device, updates, diagnostics, privacy, storage, and legal information.":
        "Gerencie dispositivo, atualizações, diagnóstico, privacidade, armazenamento e informações legais.",
    "Setup, device compatibility, calibration, and diagnostics.":
        "Configuração, compatibilidade, calibração e diagnóstico.",
    "Change setup method or reconnect your services.":
        "Altere o método de configuração ou reconecte serviços.",
    "Adjust display fit, input, and playback compatibility.":
        "Ajuste tela, entrada e compatibilidade de reprodução.",
    "Review system health and export troubleshooting details.":
        "Confira a saúde do sistema e exporte dados de diagnóstico.",
    "Stable public releases download directly to this device.":
        "Versões públicas estáveis são baixadas diretamente neste dispositivo.",
    "Download signed updates automatically when a newer build is available.":
        "Baixar atualizações assinadas automaticamente quando houver uma versão nova.",
    "Check this channel and open Android’s installer when the package is ready.":
        "Verifique este canal e abra o instalador do Android quando estiver pronto.",
    "Fetch the signed release list for the selected update channel.":
        "Buscar versões assinadas do canal selecionado.",
    "Signed releases download securely from the official TetoTV repository.":
        "Versões assinadas são baixadas com segurança do repositório oficial do TetoTV.",
    "Remove temporary files or return TetoTV to first-time setup.":
        "Remova arquivos temporários ou volte à configuração inicial do TetoTV.",
    "Remove temporary images, playback cache, and update leftovers. Accounts and settings stay saved.":
        "Remova imagens temporárias, cache e restos de atualizações. Contas e configurações são mantidas.",
    "Erase accounts, preferences, sources, and history, then return to first-time setup.":
        "Apague contas, preferências, fontes e histórico e volte à configuração inicial.",
    "Privacy, attribution, and open-source notices.":
        "Privacidade, atribuição e avisos de código aberto.",
    "Review what TetoTV stores, processes, and shares.":
        "Confira o que o TetoTV armazena, processa e compartilha.",
    "Read attribution and open-source license notices.":
        "Leia atribuições e licenças de código aberto.",
    "Control optional privacy-safe reporting and Beta activity signals.":
        "Controle relatórios opcionais seguros e sinais de atividade Beta.",
    "Review the optional privacy controls used by this build.":
        "Confira os controles opcionais de privacidade desta versão.",
    "Send a redacted technical report after an unexpected crash.":
        "Envie um relatório técnico anonimizado após uma falha inesperada.",
    "Include this device in the privacy-safe Beta activity count.":
        "Inclua este dispositivo na contagem anônima de atividade Beta.",
    "Validate and save this credential securely.":
        "Validar e salvar esta credencial com segurança.",
    "Open the secure device authorization flow.":
        "Abrir a autorização segura do dispositivo.",
    "Open TorBox device authorization.":
        "Abrir autorização de dispositivo TorBox.",
    "Remove the saved Real-Debrid connection.":
        "Remover a conexão salva do Real-Debrid.",
    "Remove the saved TorBox connection.": "Remover a conexão salva do TorBox.",
    "Choose your language": "Escolha seu idioma",
    "This sets the app language and preferred audio and captions. You can change them separately later.":
        "Isso define o idioma do app e as preferências de áudio e legendas. Você pode alterá-los separadamente depois.",
    "Also sets preferred audio and captions. You can change them separately in Playback.":
        "Também define o áudio e as legendas preferidos. Você pode alterá-los separadamente em Reprodução.",
    "App language": "Idioma do app",
    "Appearance": "Aparência",
    "Playback": "Reprodução",
    "Services": "Serviços",
    "Accounts": "Contas",
    "System": "Sistema",
    "Settings": "Configurações",
    "Theme & display": "Tema e exibição",
    "Theme Studio": "Estúdio de temas",
    "Title language": "Idioma dos títulos",
    "Show title style": "Estilo do título",
    "Colors": "Cores",
    "Home screen": "Tela inicial",
    "Featured hero": "Destaque principal",
    "Poster metadata": "Dados do pôster",
    "Continue watching": "Continuar assistindo",
    "Display options": "Opções de exibição",
    "Interface scale": "Escala da interface",
    "Content density": "Densidade do conteúdo",
    "Thumbnail size": "Tamanho das miniaturas",
    "Layout style": "Estilo do layout",
    "Default landing page": "Página inicial padrão",
    "Card details": "Detalhes dos cartões",
    "Input & feedback": "Entrada e resposta",
    "Home shelves": "Seções da página inicial",
    "Navigation": "Navegação",
    "Navigation size": "Tamanho da navegação",
    "Menu order": "Ordem do menu",
    "Navigation sounds": "Sons de navegação",
    "Click sounds": "Sons de clique",
    "Closed captions": "Legendas",
    "Player controls": "Controles do player",
    "Debrid streaming": "Streaming debrid",
    "Sources & stream order": "Fontes e ordem dos streams",
    "Automatic source selection": "Seleção automática de fontes",
    "Libraries & features": "Bibliotecas e recursos",
    "Streaming privacy": "Privacidade do streaming",
    "Anime tracking": "Acompanhamento de anime",
    "Profiles": "Perfis",
    "Progress & notifications": "Progresso e notificações",
    "Discord Rich Presence": "Atividade no Discord",
    "Device & support": "Dispositivo e suporte",
    "App updates": "Atualizações do app",
    "Community": "Comunidade",
    "Storage & reset": "Armazenamento e redefinição",
    "About & legal": "Sobre e informações legais",
    "Privacy & diagnostics": "Privacidade e diagnóstico",
    "Search settings": "Pesquisar configurações",
    "No matching settings": "Nenhuma configuração encontrada",
    "No matching settings found": "Nenhuma configuração encontrada",
    "Expand all": "Expandir tudo",
    "Collapse all": "Recolher tudo",
    "Back": "Voltar",
    "Close": "Fechar",
    "Continue": "Continuar",
    "Cancel": "Cancelar",
    "Delete": "Excluir",
    "Save": "Salvar",
    "Use": "Usar",
    "OK": "OK",
    "Try again": "Tentar novamente",
    "Refresh": "Atualizar",
    "Reset defaults": "Restaurar padrões",
    "On": "Ativado",
    "Off": "Desativado",
    "Automatic": "Automático",
    "Small": "Pequeno",
    "Medium": "Médio",
    "Large": "Grande",
    "Compact": "Compacto",
    "Standard": "Padrão",
    "Comfortable": "Confortável",
    "Cinematic": "Cinematográfico",
    "Home": "Início",
    "Search": "Pesquisar",
    "My List": "Minha lista",
    "Discover": "Descobrir",
    "Calendar": "Calendário",
    "Watch Party": "Sala de reprodução",
    "Downloads": "Downloads",
    "Play": "Reproduzir",
    "Text title": "Título em texto",
    "Title logo": "Logo do título",
    "Top row": "Linha superior",
    "Profile menu": "Menu do perfil",
    "Local profiles": "Perfis locais",
    "New local profile": "Novo perfil local",
    "Display name": "Nome de exibição",
    "No local profiles yet.": "Ainda não há perfis locais.",
    "Select to enter a name": "Selecione para digitar um nome",
    "Select to open the TV keyboard": "Selecione para abrir o teclado da TV",
    "Default player": "Player padrão",
    "Preferred audio": "Áudio preferido",
    "Preferred audio language": "Idioma de áudio preferido",
    "Preferred CC": "Legendas preferidas",
    "Preferred subtitle language": "Idioma de legenda preferido",
    "Follow Dub/Sub": "Seguir dublado/legendado",
    "English for Dubbed, Japanese for Subtitled":
        "Inglês para dublado, japonês para legendado",
    "Media3 (Built in)": "Media3 (Integrado)",
    "MPV (Built in)": "MPV (Integrado)",
    "Media3 SurfaceView": "Media3 SurfaceView",
    "External player": "Player externo",
    "Auto-skip intros": "Pular aberturas automaticamente",
    "Auto-skip outros": "Pular encerramentos automaticamente",
    "Rewind": "Retroceder",
    "Fast-forward": "Avançar",
    "Text color": "Cor do texto",
    "Background": "Fundo",
    "Text size": "Tamanho do texto",
    "Filler episode labels": "Rótulos de episódios filler",
    "Debrid provider": "Provedor debrid",
    "Debrid streams": "Streams debrid",
    "Web streams": "Streams web",
    "Direct peer streaming": "Streaming direto entre pares",
    "Manage sources": "Gerenciar fontes",
    "Debrid results": "Resultados debrid",
    "Source priority": "Prioridade de fontes",
    "Quality priority": "Prioridade de qualidade",
    "Preferred Web quality": "Qualidade web preferida",
    "Automatic selection": "Seleção automática",
    "Strict audio": "Filtro estrito de áudio",
    "Local, Jellyfin & Plex sources": "Fontes locais, Jellyfin e Plex",
    "Offline downloads": "Downloads offline",
    "Download manager": "Gerenciador de downloads",
    "Anime-list provider": "Provedor da lista de anime",
    "When to update episode progress": "Quando atualizar o progresso",
    "Sub & simulcast alerts": "Alertas de legendados e simulcast",
    "Verified dub alerts": "Alertas de dublagens confirmadas",
    "Discord presence": "Atividade no Discord",
    "Disconnect": "Desconectar",
    "Connect Discord": "Conectar Discord",
    "Unlink Discord": "Desvincular Discord",
    "Connect by QR": "Conectar por QR",
    "Personal API token": "Token de API pessoal",
    "Personal API key": "Chave de API pessoal",
    "Personal Access Token": "Token de acesso pessoal",
    "Manual API token": "Token de API manual",
    "TorBox API token": "Token de API do TorBox",
    "Run setup again": "Refazer configuração",
    "Device calibration": "Calibração do dispositivo",
    "Diagnostics": "Diagnóstico",
    "Update channel": "Canal de atualizações",
    "Release history": "Histórico de versões",
    "Check now": "Verificar agora",
    "Choose a compatible signed release":
        "Escolha uma versão assinada compatível",
    "Privacy & data": "Privacidade e dados",
    "Third-party notices": "Avisos de terceiros",
    "Anonymous crash reports": "Relatórios anônimos de falhas",
    "Anonymous live count": "Contagem ativa anônima",
    "Reset appearance and navigation": "Redefinir aparência e navegação",
    "Reset appearance & navigation": "Redefinir aparência e navegação",
    "Reset all TetoTV data?": "Apagar todos os dados do TetoTV?",
    "Erase everything": "Apagar tudo",
    "Keep my data": "Manter meus dados",
    "Cancel reset": "Cancelar redefinição",
    "Final confirmation": "Confirmação final",
    "Support TetoTV": "Apoiar o TetoTV",
    "Join the TetoTV Discord": "Entre no Discord do TetoTV",
    "Copy Discord invite": "Copiar convite do Discord",
    "Discord invite copied.": "Convite do Discord copiado.",
    "Copy Ko-fi link": "Copiar link do Ko-fi",
    "Ko-fi donation link copied.": "Link de doação do Ko-fi copiado.",
  },
  'fr': {
    "Current {version}{latest}": "Actuelle {version}{latest}",
    "Anonymous crash reports start enabled on new installs and are optional. Existing installs keep their current choice. You can turn them off here or anytime in Settings. Reports contain only the app/build, error type and time, Android version, CPU architecture, device class, and a redacted technical trace. They never include a show, episode, account, device ID, source, or URL.":
        "Les rapports de plantage anonymes sont activés au départ uniquement sur les nouvelles installations et restent facultatifs. Les installations existantes conservent leur choix actuel. Vous pouvez les désactiver ici ou à tout moment dans les paramètres. Les rapports contiennent uniquement l’appli/build, le type et l’heure de l’erreur, la version Android, l’architecture CPU, la catégorie d’appareil et une trace technique expurgée. Ils n’incluent jamais de série, épisode, compte, identifiant d’appareil, source ou URL.",
    "The Beta live count shares only whether TetoTV is active or has an MPV player open. It contains no profile or media details; normal HTTPS delivery and short-lived abuse limits may process an IP address, but the presence record does not store it.":
        "Le compteur bêta indique seulement si TetoTV est actif ou si un lecteur MPV est ouvert. Aucun profil ni média ; HTTPS et les limites anti-abus temporaires peuvent traiter l’IP, mais le registre de présence ne la conserve pas.",
    "Installed version: {version}{date}": "Version installée : {version}{date}",
    "Latest {channel}: {version}": "Dernière {channel} : {version}",
    "Latest {version}": "Dernière {version}",
    "Downloading {percent}%": "Téléchargement {percent} %",
    "Loading releases…": "Chargement des versions…",
    "Load release history": "Charger l’historique des versions",
    "Opening installer…": "Ouverture de l’installateur…",
    "Install update": "Installer la mise à jour",
    "Check for updates": "Rechercher des mises à jour",
    "Automatic: ON": "Automatique : OUI",
    "Automatic: OFF": "Automatique : NON",
    "Apply theme": "Appliquer le thème",
    "Theme applied.": "Thème appliqué.",
    "TetoTV colors restored.": "Couleurs TetoTV rétablies.",
    "Fix the contrast warnings or turn off the safeguard.":
        "Corrigez les avertissements de contraste ou désactivez la protection.",
    "The readability safeguard blocked this theme.":
        "La protection de lisibilité a bloqué ce thème.",
    "Trackers store whole completed episodes, so the selected percentage marks the current episode watched.":
        "Les comptes de suivi enregistrent des épisodes entiers ; le pourcentage choisi marque l’épisode actuel vu.",
    "Checking installed video players…": "Vérification des lecteurs installés…",
    "External apps can only receive safe, header-free streams. Private Plex and Jellyfin sessions stay in TetoTV.":
        "Les applis externes reçoivent seulement des flux sûrs sans en-têtes. Les sessions privées Plex et Jellyfin restent dans TetoTV.",
    "Adds an Open externally action for compatible streams. Turning this off returns an external default to Media3; your built-in player choice stays selected. TetoTV never shares account headers or private-server credentials.":
        "Ajoute Ouvrir en externe aux flux compatibles. Désactiver rétablit Media3 si un lecteur externe était choisi ; le lecteur intégré choisi reste inchangé. TetoTV ne partage jamais les en-têtes de compte ni les identifiants privés.",
    "Reorder": "Réordonner",
    "English logo": "Logo anglais",
    "Copy full report": "Copier le rapport complet",
    "Export full report": "Exporter le rapport complet",
    "Full redacted report copied.": "Rapport complet expurgé copié.",
    "Send diagnostic report?": "Envoyer le rapport de diagnostic ?",
    "Send report": "Envoyer le rapport",
    "The diagnostic report could not be sent. Try again shortly.":
        "Le rapport de diagnostic n’a pas pu être envoyé. Réessayez bientôt.",
    "Support report": "Rapport d’assistance",
    "Recent redacted events": "Événements récents expurgés",
    "Playback session timelines": "Chronologie des sessions de lecture",
    "Started vs failed playback": "Lectures démarrées et échouées",
    "Started session": "Session démarrée",
    "Failed session": "Session échouée",
    "No recent playback or provider failures.":
        "Aucun échec récent de lecture ou de fournisseur.",
    "No correlated playback sessions have been recorded yet.":
        "Aucune session de lecture corrélée n’a encore été enregistrée.",
    "A session that started and a failed session are needed before TetoTV can compare them. This is not a smooth-versus-stuttering comparison.":
        "TetoTV a besoin d’une session démarrée et d’une session échouée pour les comparer. Ce n’est pas une comparaison de fluidité.",
    "Privacy-safe stages correlate source selection, stream opening, decoder choice, fallback attempts, and the final result. Media names, addresses, URLs, filenames, headers, and server IDs are never shown.":
        "Ces étapes confidentielles relient source, ouverture du flux, décodeur, tentatives de repli et résultat. Noms de médias, adresses, URL, fichiers, en-têtes et identifiants serveur ne sont jamais affichés.",
    "Started means video parameters became available, not that playback was smooth. Decoder choice is a requested policy; the full report includes sampled engine performance when available. UI frame timings describe the app interface, not video frame rate or dropped video frames.":
        "Démarrée signifie que les paramètres vidéo étaient disponibles, pas que la lecture était fluide. Le décodeur indique la stratégie demandée ; le rapport complet contient des mesures disponibles. Les temps d’interface ne mesurent ni les FPS vidéo ni ses images perdues.",
    "A complete bounded dump of device capabilities, player health, performance timings, provider health, and the preceding 48 hours of persisted app events and crash summaries. Account identity, credentials, watch-room secrets, direct media sources, URLs, file paths, and network addresses are removed before it leaves the TV.":
        "Rapport complet de taille limitée : capacités de l’appareil, état du lecteur et des fournisseurs, performances et événements et plantages des 48 dernières heures. Identité, identifiants, secrets des salons, sources directes, URL, chemins et adresses réseau sont retirés avant l’envoi.",
    "This posts the complete bounded, redacted technical dump shown in Diagnostics to TetoTV’s private Discord support channel. It includes the app build, device capabilities, player and provider health, performance timings, and the preceding 48 hours of persisted events and crash summaries. Account identity, credentials, watch-room secrets, direct media sources, file paths, and network addresses are excluded.":
        "Cela envoie le rapport technique complet, limité et expurgé des Diagnostics au salon privé d’assistance Discord TetoTV. Il inclut version, capacités, état du lecteur et des fournisseurs, performances et événements et plantages des 48 dernières heures. Identité, identifiants, secrets de salons, sources directes, chemins et adresses réseau sont exclus.",
    "Save recommendation": "Enregistrer la recommandation",
    "Scan again": "Analyser à nouveau",
    "Video decoders": "Décodeurs vidéo",
    "TetoTV scans Android’s decoders, display, audio output, and subtitle engine.":
        "TetoTV analyse les décodeurs, l’écran, la sortie audio et le moteur de sous-titres Android.",
    "The privacy disclosure could not be loaded.":
        "Les informations de confidentialité n’ont pas pu être chargées.",
    "Third-party notices could not be loaded.":
        "Les mentions tierces n’ont pas pu être chargées.",
    "Third-party notices document": "Document des mentions tierces",
    "This device does not support resetting TetoTV.":
        "Cet appareil ne permet pas de réinitialiser TetoTV.",
    "This device does not support TetoTV cache cleanup.":
        "Cet appareil ne permet pas de vider le cache TetoTV.",
    "Direct torrent is unavailable": "Torrent direct indisponible",
    "This build supports direct torrent playback and downloads on ARM32 and ARM64 Android devices. It is unavailable on this device architecture.":
        "Cette version permet les torrents directs sur Android ARM32 et ARM64. Cette architecture d’appareil n’est pas prise en charge.",
    "Enable direct peer torrents?":
        "Activer les torrents directs entre pairs ?",
    "Enable direct peers": "Activer les pairs directs",
    "Keep off": "Laisser désactivé",
    "This connects directly to public torrent peers without a debrid account. Your public IP address is visible to peers and trackers, and selected episode data may upload while you watch or download. Streaming may use up to 6 GB of temporary storage; offline files remain until you delete them in Download Manager. Only access content you are legally allowed to use.":
        "Connexion directe aux pairs torrent publics sans compte debrid. Votre IP publique est visible par les pairs et trackers ; des données d’épisode peuvent être envoyées pendant le visionnage ou téléchargement. Jusqu’à 6 Go temporaires peuvent être utilisés ; les fichiers hors ligne restent jusqu’à suppression. Utilisez seulement du contenu légalement autorisé.",
    "Not installed — TetoTV will fall back to Media3":
        "Non installé — TetoTV utilisera Media3",
    "Offer installed video players for compatible, header-free streams.":
        "Proposer les lecteurs installés pour les flux compatibles sans en-têtes.",
    "Open externally": "Ouvrir en externe",
    "Choose which buttons are shown and move them into your preferred order. Settings can move to the profile menu, with a top-row fallback on small screens or when no profile is linked.":
        "Choisissez les boutons visibles et leur ordre. Les paramètres peuvent aller au menu du profil, avec un accès supérieur sur petit écran ou sans profil lié.",
    "Entries marked Blocked by Android remain visible for reference but cannot be selected. Android cannot replace this installation with a lower build code; Developer Mode cannot bypass that rule. A same-or-higher-code rebuild can roll back while preserving data.":
        "Les entrées Bloqué par Android restent visibles mais non sélectionnables. Android refuse un numéro de build inférieur ; le mode développeur ne contourne pas cette règle. Une recompilation avec un code égal ou supérieur permet de revenir en arrière sans perdre les données.",
    "Join the TetoTV Discord for announcements, support, and feature requests.":
        "Rejoignez le Discord TetoTV pour annonces, assistance et suggestions.",
    "Scan the code with your phone, or select the invite below to copy it.":
        "Scannez le code avec votre téléphone ou sélectionnez l’invitation pour la copier.",
    "Donations are optional. Scan with your phone to open the official TetoTV Ko-fi page, or select the link below to copy it.":
        "Les dons sont facultatifs. Scannez avec votre téléphone pour ouvrir le Ko-fi officiel TetoTV ou sélectionnez le lien pour le copier.",
    "Optional. When enabled, Discord can show the anime title, episode, playing or paused state, and playback timer. TetoTV never asks for or stores your Discord password.":
        "Facultatif. Discord peut afficher titre, épisode, lecture ou pause et durée. TetoTV ne demande ni ne stocke jamais votre mot de passe Discord.",
    "Development disclosure: TetoTV includes code created and reviewed with AI-assisted development tools. Releases are tested and maintained by the project owner.":
        "Développement : TetoTV contient du code créé et vérifié avec des outils assistés par IA. Le propriétaire du projet teste et maintient les versions.",
    "TetoTV is an independent, unofficial client. It is not affiliated with or endorsed by AniList, MAL, Kitsu, SIMKL, debrid services, addon authors, or media rights holders. Users add and are responsible for their own services and repositories.":
        "TetoTV est un client indépendant non officiel, sans affiliation ni approbation d’AniList, MAL, Kitsu, SIMKL, services debrid, auteurs d’extensions ou ayants droit. Les utilisateurs ajoutent leurs services et dépôts et en sont responsables.",
    "Reports may include the app version, Android version, device class, error type, time, and a redacted trace. They never include what you watch, accounts, device IDs, sources, or URLs.":
        "Les rapports peuvent inclure versions de l’appli et d’Android, catégorie d’appareil, erreur, heure et trace expurgée. Jamais le contenu regardé, comptes, identifiants d’appareil, sources ou URL.",
    "Shares only whether this Beta app process is active or has an MPV player open. A paused or loading player can still count as watching. No profile, title, episode, source, device ID, URL, or media information is sent. HTTPS and abuse limits may process your IP, but it is not stored in the presence record.":
        "Partage uniquement si le processus bêta est actif ou si un lecteur MPV est ouvert. Pause ou chargement peuvent compter comme visionnage. Aucun profil, titre, épisode, source, identifiant d’appareil, URL ou média n’est envoyé. HTTPS et les limites anti-abus peuvent traiter l’IP, sans la stocker dans le registre de présence.",
    "{step} of {count}": "{step} sur {count}",
    "{count} selected": "{count} sélectionnés",
    "{count} sources added": "{count} sources ajoutées",
    "Delete {name}?": "Supprimer {name} ?",
    "Connected as {name}. Lists and episode progress sync automatically.":
        "Connecté en tant que {name}. Les listes et la progression sont synchronisées automatiquement.",
    "Build: {number}": "Build : {number}",
    "Prefer dubbed sources. Track selection follows Preferred audio language.":
        "Préférer les sources doublées. La piste suit la langue audio préférée.",
    "Prefer subtitled sources. Track selection follows Preferred audio language.":
        "Préférer les sources sous-titrées. La piste suit la langue audio préférée.",
    "Preparing secure phone setup…":
        "Préparation de la configuration sécurisée par téléphone…",
    "Secure setup resumed.": "Configuration sécurisée reprise.",
    "Finishing the setup already applied on this device…":
        "Finalisation de la configuration déjà appliquée…",
    "Scan the QR code or enter the code on your phone.":
        "Scannez le QR ou saisissez le code sur votre téléphone.",
    "Secure phone setup could not start. Check the connection and try again.":
        "La configuration sécurisée n’a pas pu démarrer. Vérifiez la connexion et réessayez.",
    "Waiting for your phone to connect…":
        "En attente de connexion du téléphone…",
    "Phone connected. Your progress is saved while you finish setup.":
        "Téléphone connecté. Votre progression est enregistrée pendant la configuration.",
    "The encrypted setup did not pass validation. Review it on your phone and send it again.":
        "La configuration chiffrée n’a pas été validée. Vérifiez-la sur votre téléphone et renvoyez-la.",
    "Review what will be added. Account secrets remain hidden.":
        "Vérifiez les ajouts. Les secrets des comptes restent masqués.",
    "Phone setup is complete.": "Configuration par téléphone terminée.",
    "The phone rejected or could not finish this setup. Try again.":
        "Le téléphone a refusé ou n’a pas pu terminer la configuration. Réessayez.",
    "Connection interrupted. TetoTV will keep trying securely in the background.":
        "Connexion interrompue. TetoTV réessaiera en sécurité en arrière-plan.",
    "Verifying accounts and applying your choices…":
        "Vérification des comptes et application des choix…",
    "Your choices are saved. Reconnecting to confirm completion…":
        "Vos choix sont enregistrés. Reconnexion pour confirmer…",
    "Setup could not be applied. Nothing was sent back; try again.":
        "La configuration n’a pas pu être appliquée. Rien n’a été renvoyé ; réessayez.",
    "Returning this setup to your phone for changes…":
        "Renvoi de la configuration au téléphone pour modification…",
    "Make your changes on the phone, then send them again.":
        "Effectuez vos modifications sur le téléphone, puis renvoyez-les.",
    "Could not return the setup yet. Try again.":
        "La configuration n’a pas encore pu être renvoyée. Réessayez.",
    "Creating a fresh secure setup code…":
        "Création d’un nouveau code sécurisé…",
    "Invalidating the old code before creating a new one…":
        "Invalidation de l’ancien code avant d’en créer un nouveau…",
    "A new secure setup code is ready.":
        "Nouveau code de configuration sécurisé prêt.",
    "The old code could not be replaced securely. Check the connection and try again.":
        "L’ancien code n’a pas pu être remplacé en sécurité. Vérifiez la connexion et réessayez.",
    "This setup session expired. Create a new secure code.":
        "Cette session a expiré. Créez un nouveau code sécurisé.",
    "Protected with end-to-end encryption. You sign in only on each service's official page; TetoTV never asks for passwords. The setup companion holds the resulting credentials only temporarily, then your browser encrypts them for this device. Credentials never appear in the QR code, URL, browser draft storage, logs, or diagnostics. After your phone connects, the page can be minimized and reopened without losing the setup draft.":
        "Protégé par chiffrement de bout en bout. Vous vous connectez seulement sur la page officielle de chaque service ; TetoTV ne demande jamais de mot de passe. Le compagnon conserve temporairement les identifiants, puis le navigateur les chiffre pour cet appareil. Ils n’apparaissent jamais dans le QR, l’URL, le brouillon du navigateur, les journaux ou diagnostics. Après connexion, la page peut être réduite puis rouverte sans perdre le brouillon.",
    "Make TetoTV yours": "Personnalisez TetoTV",
    "Change the app canvas, panels, focus color and text. Your saved theme is shared by phone and TV layouts.":
        "Changez fond, panneaux, couleur de focus et texte. Le thème enregistré est commun au téléphone et à la TV.",
    "App colors": "Couleurs de l’appli",
    "Panels & surfaces": "Panneaux et surfaces",
    "Accent, focus & hover": "Accent, focus et survol",
    "Primary text": "Texte principal",
    "Muted text": "Texte atténué",
    "App canvas and page backgrounds": "Fond de l’appli et des pages",
    "Cards, menus and dialog panels": "Fiches, menus et boîtes de dialogue",
    "Selection, focus rings and primary actions":
        "Sélection, contours de focus et actions principales",
    "Headings and important labels": "Titres et libellés importants",
    "Descriptions and secondary labels": "Descriptions et libellés secondaires",
    "Featured show": "Série à la une",
    "Continue watching · Episode 7": "Reprendre · Épisode 7",
    "Your library": "Votre bibliothèque",
    "Panels, labels and focus states update here.":
        "Les panneaux, libellés et états de focus sont actualisés ici.",
    "Focused": "Sélectionné",
    "Protect readable contrast": "Préserver un contraste lisible",
    "Prevents a theme from hiding text or TV focus rings.":
        "Empêche un thème de masquer le texte ou les contours de focus TV.",
    "Low-contrast theme allowed because the safeguard is off.":
        "Thème peu contrasté autorisé car la protection est désactivée.",
    "Choose a built-in color with the D-pad. Exact hex entry is available as an optional advanced choice.":
        "Choisissez une couleur avec la télécommande. La saisie hexadécimale exacte est une option avancée.",
    "Selected color": "Couleur sélectionnée",
    "Built-in colors": "Couleurs intégrées",
    "Built-in remote color picker": "Sélecteur de couleurs à la télécommande",
    "Exact hex color": "Couleur hexadécimale exacte",
    "Use color": "Utiliser la couleur",
    "Live theme preview": "Aperçu du thème",
    "Built-in": "Intégré",
    "Click": "Clic",
    "Display": "Affichage",
    "Device": "Appareil",
    "App": "Appli",
    "Privacy": "Confidentialité",
    "Home & navigation": "Accueil et navigation",
    "Home content": "Contenu d’accueil",
    "Interface sounds": "Sons de l’interface",
    "Featured": "À la une",
    "First": "Premier",
    "Active": "Actif",
    "Optional": "Facultatif",
    "Connected": "Connecté",
    "Not connected": "Non connecté",
    "Linked": "Lié",
    "Not linked": "Non lié",
    "Disabled": "Désactivé",
    "Unavailable": "Indisponible",
    "Ready": "Prêt",
    "Reconnect": "Reconnecter",
    "Checking": "Vérification",
    "Checking…": "Vérification…",
    "Loading…": "Chargement…",
    "Saving…": "Enregistrement…",
    "Please wait…": "Veuillez patienter…",
    "Manage": "Gérer",
    "Create": "Créer",
    "Save & verify": "Enregistrer et vérifier",
    "Add profile": "Ajouter un profil",
    "Shown": "Affiché",
    "Hidden": "Masqué",
    "Discord account": "Compte Discord",
    "Discord account linked": "Compte Discord lié",
    "Checking Discord": "Vérification de Discord",
    "Unavailable on this device": "Indisponible sur cet appareil",
    "Retry connection": "Réessayer la connexion",
    "Disable Rich Presence": "Désactiver l’activité Discord",
    "Enable Rich Presence": "Activer l’activité Discord",
    "Authorize TetoTV through Discord’s secure account-linking flow.":
        "Autorisez TetoTV via la procédure de connexion sécurisée Discord.",
    "Control whether your current playback appears on Discord.":
        "Contrôlez si votre lecture actuelle apparaît sur Discord.",
    "Turn Rich Presence back on for this linked account.":
        "Réactivez l’activité pour ce compte lié.",
    "Connect SIMKL": "Connecter SIMKL",
    "Reconnect SIMKL": "Reconnecter SIMKL",
    "Reconnect SIMKL to verify this saved account.":
        "Reconnectez SIMKL pour vérifier ce compte enregistré.",
    "Link SIMKL securely through its official sign-in page.":
        "Liez SIMKL en sécurité via sa page de connexion officielle.",
    "SIMKL sign-in must be enabled on the TetoTV companion first.":
        "La connexion SIMKL doit d’abord être activée sur le compagnon TetoTV.",
    "Remove the saved SIMKL connection from TetoTV.":
        "Supprimez la connexion SIMKL enregistrée dans TetoTV.",
    "Replace the saved connection through SIMKL’s secure sign-in.":
        "Remplacez la connexion enregistrée via la connexion sécurisée SIMKL.",
    "Open the secure SIMKL authorization flow.":
        "Ouvrir l’autorisation sécurisée SIMKL.",
    "Clearing cache…": "Suppression du cache…",
    "Clear cache": "Vider le cache",
    "Resetting TetoTV…": "Réinitialisation de TetoTV…",
    "Reset TetoTV": "Réinitialiser TetoTV",
    "Currently installed": "Actuellement installée",
    "Same build number • package and signature checked before install":
        "Même numéro de build • paquet et signature vérifiés avant installation",
    "Older release • Android build compatibility checked before download":
        "Ancienne version • compatibilité Android vérifiée avant téléchargement",
    "Newer release • package and signature checked before install":
        "Nouvelle version • paquet et signature vérifiés avant installation",
    "Not reported": "Non indiqué",
    "Developer update tools": "Outils de mise à jour développeur",
    "History enabled": "Historique activé",
    "Switch channels or inspect signed release history. Android only installs the same or a higher build code.":
        "Changez de canal ou consultez les versions signées. Android installe uniquement un numéro de build égal ou supérieur.",
    "Choose Public or Beta. Beta builds may be less stable.":
        "Choisissez Public ou Bêta. Les versions bêta peuvent être moins stables.",
    "Secure updates ready": "Mises à jour sécurisées prêtes",
    "What’s new": "Nouveautés",
    "Creating a secure session": "Création d’une session sécurisée",
    "Waiting for your phone": "En attente de votre téléphone",
    "Phone connected": "Téléphone connecté",
    "Review before applying": "Vérifiez avant d’appliquer",
    "Applying securely": "Application sécurisée",
    "Setup complete": "Configuration terminée",
    "Code expired": "Code expiré",
    "Setup unavailable": "Configuration indisponible",
    "Selected account": "Compte sélectionné",
    "Selected service": "Service sélectionné",
    "Preferences": "Préférences",
    "Marketplace repositories": "Dépôts Marketplace",
    "Torrent manifests": "Manifestes torrent",
    "Debrid service": "Service debrid",
    "Authorized securely": "Autorisé en sécurité",
    "Connect after setup": "Connecter après la configuration",
    "Skip": "Ignorer",
    "How would you like to set up TetoTV?":
        "Comment voulez-vous configurer TetoTV ?",
    "Choose the setup method that works best for you.":
        "Choisissez la méthode qui vous convient.",
    "You can adjust these choices later in Settings.":
        "Vous pourrez modifier ces choix dans les paramètres.",
    "Preparing setup…": "Préparation de la configuration…",
    "First-run setup": "Première configuration",
    "Setup on device": "Configurer sur cet appareil",
    "Setup on another device": "Configurer sur un autre appareil",
    "Simple on-device setup": "Configuration simple sur l’appareil",
    "Phone-friendly setup": "Configuration sur téléphone",
    "Simple D-pad setup": "Configuration simple avec la télécommande",
    "Optimized for touch": "Optimisé pour le tactile",
    "Complete every setup step directly on this device.":
        "Effectuez toute la configuration sur cet appareil.",
    "Use a phone, tablet, or computer while this device stays on the setup screen.":
        "Utilisez un téléphone, une tablette ou un ordinateur en laissant cet appareil sur l’écran de configuration.",
    "Leave setup?": "Quitter la configuration ?",
    "You can finish these choices later from Settings.":
        "Vous pourrez terminer ces choix dans les paramètres.",
    "Keep setting up": "Continuer la configuration",
    "Set up later": "Configurer plus tard",
    "Set up TetoTV": "Configurer TetoTV",
    "Choose your playback defaults": "Choisissez vos préférences de lecture",
    "Set your language, subtitles, input, and skipping.":
        "Réglez la langue, les sous-titres, la saisie et les sauts.",
    "Audio & subtitle default": "Audio et sous-titres par défaut",
    "Anime title language": "Langue des titres d’anime",
    "Text input": "Saisie de texte",
    "TetoTV keyboard": "Clavier TetoTV",
    "Device keyboard": "Clavier de l’appareil",
    "On-screen keyboard": "Clavier à l’écran",
    "Automatic skipping": "Sauts automatiques",
    "Skip intros": "Ignorer les génériques de début",
    "Skip outros": "Ignorer les génériques de fin",
    "Connect your accounts": "Connectez vos comptes",
    "Sync your watchlist and Discord presence, or skip either one.":
        "Synchronisez votre liste et l’activité Discord, ou ignorez l’une des deux.",
    "Anime list": "Liste d’anime",
    "Connections are optional. TetoTV never sees or stores your account passwords.":
        "Les connexions sont facultatives. TetoTV ne voit ni ne stocke jamais vos mots de passe.",
    "Set up streaming": "Configurer le streaming",
    "Connect providers and choose how episode sources are found.":
        "Connectez des fournisseurs et choisissez comment trouver les sources d’épisodes.",
    "Choose a debrid provider if you use one. Connecting it now is optional.":
        "Choisissez un fournisseur debrid si vous en utilisez un. La connexion est facultative.",
    "Your sources": "Vos sources",
    "Add only repositories and manifests you trust and are authorized to use. TetoTV does not bundle or recommend sources.":
        "Ajoutez uniquement des dépôts et manifestes fiables que vous êtes autorisé à utiliser. TetoTV ne fournit ni ne recommande de sources.",
    "Add sources with phone": "Ajouter des sources par téléphone",
    "Open Marketplace manually": "Ouvrir le Marketplace manuellement",
    "One last choice": "Un dernier choix",
    "Allow error reports": "Autoriser les rapports d’erreurs",
    "Do not send": "Ne pas envoyer",
    "Anonymous crash and error reports":
        "Rapports de plantages et d’erreurs anonymes",
    "Anonymous Beta live count": "Compteur d’activité anonyme bêta",
    "Count me in": "M’inclure",
    "Opt out": "Ne pas participer",
    "Set up with phone": "Configurer avec un téléphone",
    "One secure setup for accounts, Discord, sources, debrid, and preferences":
        "Une configuration sécurisée pour les comptes, Discord, les sources, debrid et les préférences",
    "Connect your phone": "Connectez votre téléphone",
    "Open secure setup page": "Ouvrir la page de configuration sécurisée",
    "Match this on both screens":
        "Vérifiez la correspondance sur les deux écrans",
    "Edit on phone": "Modifier sur le téléphone",
    "Apply setup": "Appliquer la configuration",
    "Start TetoTV": "Démarrer TetoTV",
    "Regenerate code": "Générer un nouveau code",
    "Set up on this device instead": "Configurer plutôt sur cet appareil",
    "Use on-device setup instead": "Configurer plutôt sur l’appareil",
    "No browser could open the secure setup page.":
        "Aucun navigateur n’a pu ouvrir la page de configuration sécurisée.",
    "Account credentials are end-to-end encrypted and intentionally hidden from this preview. Linked services use their official authorization pages; passwords are never included.":
        "Les identifiants sont chiffrés de bout en bout et masqués dans cet aperçu. Les services utilisent leurs pages officielles d’autorisation ; les mots de passe ne sont jamais inclus.",
    "Anime tracking connected": "Suivi d’anime connecté",
    "Discord connected": "Discord connecté",
    "Debrid service connected": "Service debrid connecté",
    "Encrypted setup verified": "Configuration chiffrée vérifiée",
    "Preferences saved": "Préférences enregistrées",
    "Navigation & logo size": "Taille de navigation et du logo",
    "Navigation bar": "Barre de navigation",
    "Home layout": "Disposition d’accueil",
    "Home details": "Détails d’accueil",
    "Poster badges": "Badges d’affiche",
    "Finish": "Terminer",
    "Choose how Home looks and keep your everyday shortcuts close.":
        "Personnalisez l’accueil et gardez vos raccourcis à portée de main.",
    "Modern Layout": "Disposition moderne",
    "Classic Layout (retired)": "Disposition classique (retirée)",
    "After 50%": "Après 50 %",
    "After 75%": "Après 75 %",
    "After 90%": "Après 90 %",
    "At episode end": "À la fin de l’épisode",
    "Mark the episode watched once half of it has played.":
        "Marquer l’épisode vu après la moitié de sa durée.",
    "Mark the episode watched after three quarters has played.":
        "Marquer l’épisode vu après les trois quarts de sa durée.",
    "Mark the episode watched near the end (recommended).":
        "Marquer l’épisode vu vers la fin (recommandé).",
    "Only mark the episode watched after playback finishes.":
        "Marquer l’épisode vu seulement à la fin de la lecture.",
    "Use the preferred language when captions are needed.":
        "Utiliser la langue préférée si des sous-titres sont nécessaires.",
    "Start captions on when a matching track is available.":
        "Activer les sous-titres si une piste correspondante est disponible.",
    "Start playback with captions off.":
        "Démarrer la lecture sans sous-titres.",
    "Any": "Tous",
    "Debrid only": "Debrid uniquement",
    "Web only": "Web uniquement",
    "Use the preferred source order": "Utiliser l’ordre préféré des sources",
    "Automatically select cached releases":
        "Choisir automatiquement les versions en cache",
    "Automatically select Web streams": "Choisir automatiquement les flux web",
    "Local library": "Bibliothèque locale",
    "Cached torrent and debrid releases": "Versions torrent et debrid en cache",
    "Marketplace Web streams": "Flux web du Marketplace",
    "Exact episode matches from local, Jellyfin, or Plex libraries":
        "Correspondances exactes dans les bibliothèques locales, Jellyfin ou Plex",
    "Allow every available resolution": "Autoriser toutes les résolutions",
    "Dub only": "Doublage uniquement",
    "Sub only": "Sous-titré uniquement",
    "Allow dubbed or subtitled streams":
        "Autoriser les flux doublés ou sous-titrés",
    "Require English audio support": "Exiger un audio anglais",
    "Require original audio support": "Exiger un audio original",
    "TetoTV built-in player": "Lecteur intégré TetoTV",
    "Built-in Android player with TetoTV controls":
        "Lecteur Android intégré avec commandes TetoTV",
    "A selected app installed on this device":
        "Une appli choisie installée sur cet appareil",
    "Personalize TetoTV, the Home screen, navigation, and feedback.":
        "Personnalisez TetoTV, l’accueil, la navigation et les retours.",
    "Customize colors and preview the TetoTV interface.":
        "Personnalisez les couleurs et prévisualisez l’interface TetoTV.",
    "Choose what appears on Home and move favorites toward the top.":
        "Choisissez les rubriques d’accueil et placez vos favoris en haut.",
    "Choose audio, skipping, seeking, and playback behavior.":
        "Configurez l’audio, les sauts et le comportement de lecture.",
    "Tune captions, player behavior, audio, skipping, and seeking.":
        "Réglez les sous-titres, le lecteur, l’audio, les sauts et l’avance.",
    "Style subtitles for comfortable viewing on every screen.":
        "Adaptez les sous-titres pour une lecture confortable sur tout écran.",
    "Compatibility engine with full TetoTV controls":
        "Moteur de compatibilité avec toutes les commandes TetoTV",
    "Default Android engine with the same TetoTV controls":
        "Moteur Android par défaut avec les mêmes commandes TetoTV",
    "SurfaceView (default). Media3 only; applies to the next video.":
        "SurfaceView (par défaut). Media3 uniquement ; s’applique à la prochaine vidéo.",
    "TextureView. Turn on to restore the default SurfaceView renderer and select Media3 for the next video.":
        "TextureView. Activez cette option pour rétablir SurfaceView comme moteur de rendu par défaut et sélectionner Media3 pour la prochaine vidéo.",
    "Skip detected opening segments automatically.":
        "Ignorer automatiquement les génériques de début détectés.",
    "Skip detected ending segments automatically.":
        "Ignorer automatiquement les génériques de fin détectés.",
    "Mark episodes identified as anime-original filler.":
        "Marquer les épisodes identifiés comme hors-série propres à l’anime.",
    "Play feedback while moving between controls.":
        "Jouer un son lors du passage entre les commandes.",
    "Play confirmation feedback when selecting an option.":
        "Jouer un son de confirmation à la sélection d’une option.",
    "Show supporting text beneath posters and media cards.":
        "Afficher du texte complémentaire sous les affiches et fiches.",
    "Choose and securely connect the provider used to resolve streams.":
        "Choisissez et connectez en sécurité le fournisseur de flux.",
    "Choose which source types are searched and how results are ranked.":
        "Choisissez les types de sources recherchés et le classement des résultats.",
    "Use cached and resolved streams from your linked service.":
        "Utiliser les flux en cache et résolus par votre service connecté.",
    "Include streams supplied by installed web addons.":
        "Inclure les flux des extensions web installées.",
    "Play torrent releases directly without a debrid service.":
        "Lire les torrents directement sans service debrid.",
    "Install, remove, and organize streaming addons.":
        "Installez, supprimez et organisez les extensions de streaming.",
    "Choose the highest-ranked playable source automatically.":
        "Choisir automatiquement la source lisible la mieux classée.",
    "Prioritize source type, quality, and audio when TetoTV chooses for you.":
        "Priorisez type de source, qualité et audio lors de la sélection automatique.",
    "Preferences change ranking only. Other usable streams remain available for manual choice and automatic failover.":
        "Les préférences modifient seulement le classement. Les autres flux utilisables restent disponibles pour la sélection manuelle et le repli automatique.",
    "TetoTV tries each source class from top to bottom.":
        "TetoTV essaie chaque type de source de haut en bas.",
    "The first available quality in this order is selected.":
        "La première qualité disponible dans cet ordre est choisie.",
    "Manage local libraries, Watch Party, and offline viewing.":
        "Gérez les bibliothèques locales, le visionnage partagé et hors ligne.",
    "Connect libraries and add local files that appear in the normal source picker.":
        "Connectez des bibliothèques et ajoutez des fichiers locaux au sélecteur de sources habituel.",
    "Review active jobs, saved episodes, and device storage.":
        "Consultez les tâches actives, épisodes enregistrés et le stockage.",
    "Control privacy-sensitive source and playback behavior.":
        "Contrôlez les comportements des sources et de lecture liés à la confidentialité.",
    "Profiles, anime tracking, notifications, and linked services.":
        "Profils, suivi d’anime, notifications et services connectés.",
    "Connect a list provider and keep episode progress synchronized.":
        "Connectez un fournisseur de listes et synchronisez la progression des épisodes.",
    "Sync Kitsu lists, episode progress, and status securely.":
        "Synchronisez de façon sécurisée les listes, la progression des épisodes et les statuts Kitsu.",
    "Manage local viewers and their separate preferences.":
        "Gérez les profils locaux et leurs préférences.",
    "Create, switch, or remove names stored locally on this device.":
        "Créez, changez ou supprimez les noms enregistrés sur cet appareil.",
    "Names are stored only on this device and never include tracker credentials. The selected name is shared with Watch Party participants.":
        "Les noms sont enregistrés seulement sur cet appareil, sans identifiants de suivi. Le nom choisi est partagé avec les participants au visionnage.",
    "This removes only the local profile name. Shared history, settings, and connected trackers stay saved.":
        "Cela supprime seulement le nom du profil local. L’historique partagé, les paramètres et les comptes de suivi restent enregistrés.",
    "Choose when progress syncs and which episode alerts appear.":
        "Choisissez quand synchroniser la progression et quelles alertes afficher.",
    "Notify when a subtitled or simulcast episode reaches its normal airtime.":
        "Avertir à l’heure de diffusion d’un épisode sous-titré ou simulcast.",
    "Notify only when a dubbed episode has a verified release schedule.":
        "Avertir uniquement si un épisode doublé a un calendrier confirmé.",
    "Control the optional Discord activity shown while you watch.":
        "Contrôlez l’activité Discord facultative pendant le visionnage.",
    "Remove this Discord connection from TetoTV on this device.":
        "Supprimez cette connexion Discord de TetoTV sur cet appareil.",
    "Manage this device, updates, diagnostics, privacy, storage, and legal information.":
        "Gérez appareil, mises à jour, diagnostics, confidentialité, stockage et mentions légales.",
    "Setup, device compatibility, calibration, and diagnostics.":
        "Configuration, compatibilité, étalonnage et diagnostics.",
    "Change setup method or reconnect your services.":
        "Changez de méthode de configuration ou reconnectez vos services.",
    "Adjust display fit, input, and playback compatibility.":
        "Réglez l’affichage, la saisie et la compatibilité de lecture.",
    "Review system health and export troubleshooting details.":
        "Vérifiez l’état du système et exportez les informations de dépannage.",
    "Stable public releases download directly to this device.":
        "Les versions publiques stables sont téléchargées sur cet appareil.",
    "Download signed updates automatically when a newer build is available.":
        "Télécharger automatiquement les mises à jour signées lorsqu’une nouvelle version est disponible.",
    "Check this channel and open Android’s installer when the package is ready.":
        "Vérifiez ce canal et ouvrez l’installateur Android quand le paquet est prêt.",
    "Fetch the signed release list for the selected update channel.":
        "Récupérer les versions signées du canal sélectionné.",
    "Signed releases download securely from the official TetoTV repository.":
        "Les versions signées sont téléchargées en sécurité depuis le dépôt officiel TetoTV.",
    "Remove temporary files or return TetoTV to first-time setup.":
        "Supprimez les fichiers temporaires ou revenez à la première configuration.",
    "Remove temporary images, playback cache, and update leftovers. Accounts and settings stay saved.":
        "Supprimez images temporaires, cache de lecture et restes de mises à jour. Comptes et paramètres restent enregistrés.",
    "Erase accounts, preferences, sources, and history, then return to first-time setup.":
        "Effacez comptes, préférences, sources et historique, puis revenez à la première configuration.",
    "Privacy, attribution, and open-source notices.":
        "Confidentialité, attributions et mentions open source.",
    "Review what TetoTV stores, processes, and shares.":
        "Consultez ce que TetoTV stocke, traite et partage.",
    "Read attribution and open-source license notices.":
        "Lisez les attributions et licences open source.",
    "Control optional privacy-safe reporting and Beta activity signals.":
        "Contrôlez les rapports facultatifs confidentiels et l’activité bêta.",
    "Review the optional privacy controls used by this build.":
        "Consultez les contrôles facultatifs de confidentialité de cette version.",
    "Send a redacted technical report after an unexpected crash.":
        "Envoyer un rapport technique expurgé après un plantage inattendu.",
    "Include this device in the privacy-safe Beta activity count.":
        "Inclure cet appareil dans le compteur confidentiel d’activité bêta.",
    "Validate and save this credential securely.":
        "Valider et enregistrer cet identifiant en sécurité.",
    "Open the secure device authorization flow.":
        "Ouvrir l’autorisation sécurisée de l’appareil.",
    "Open TorBox device authorization.":
        "Ouvrir l’autorisation d’appareil TorBox.",
    "Remove the saved Real-Debrid connection.":
        "Supprimer la connexion Real-Debrid enregistrée.",
    "Remove the saved TorBox connection.":
        "Supprimer la connexion TorBox enregistrée.",
    "Choose your language": "Choisissez votre langue",
    "This sets the app language and preferred audio and captions. You can change them separately later.":
        "Cela définit la langue de l’appli, de l’audio et des sous-titres préférés. Vous pourrez les modifier séparément.",
    "Also sets preferred audio and captions. You can change them separately in Playback.":
        "Définit aussi l’audio et les sous-titres préférés. Modifiez-les séparément dans Lecture.",
    "App language": "Langue de l’appli",
    "Appearance": "Apparence",
    "Playback": "Lecture",
    "Services": "Services",
    "Accounts": "Comptes",
    "System": "Système",
    "Settings": "Paramètres",
    "Theme & display": "Thème et affichage",
    "Theme Studio": "Atelier de thèmes",
    "Title language": "Langue des titres",
    "Show title style": "Style du titre",
    "Colors": "Couleurs",
    "Home screen": "Écran d’accueil",
    "Featured hero": "Bannière à la une",
    "Poster metadata": "Infos sur les affiches",
    "Continue watching": "Reprendre la lecture",
    "Display options": "Options d’affichage",
    "Interface scale": "Échelle de l’interface",
    "Content density": "Densité du contenu",
    "Thumbnail size": "Taille des vignettes",
    "Layout style": "Style de disposition",
    "Default landing page": "Page de démarrage",
    "Card details": "Détails des fiches",
    "Input & feedback": "Saisie et retour",
    "Home shelves": "Rubriques d’accueil",
    "Navigation": "Navigation",
    "Navigation size": "Taille de navigation",
    "Menu order": "Ordre du menu",
    "Navigation sounds": "Sons de navigation",
    "Click sounds": "Sons de clic",
    "Closed captions": "Sous-titres",
    "Player controls": "Commandes du lecteur",
    "Debrid streaming": "Streaming debrid",
    "Sources & stream order": "Sources et ordre des flux",
    "Automatic source selection": "Sélection automatique des sources",
    "Libraries & features": "Bibliothèques et fonctions",
    "Streaming privacy": "Confidentialité du streaming",
    "Anime tracking": "Suivi des anime",
    "Profiles": "Profils",
    "Progress & notifications": "Progression et notifications",
    "Discord Rich Presence": "Activité Discord",
    "Device & support": "Appareil et assistance",
    "App updates": "Mises à jour de l’appli",
    "Community": "Communauté",
    "Storage & reset": "Stockage et réinitialisation",
    "About & legal": "À propos et mentions légales",
    "Privacy & diagnostics": "Confidentialité et diagnostics",
    "Search settings": "Rechercher un paramètre",
    "No matching settings": "Aucun paramètre correspondant",
    "No matching settings found": "Aucun paramètre trouvé",
    "Expand all": "Tout développer",
    "Collapse all": "Tout réduire",
    "Back": "Retour",
    "Close": "Fermer",
    "Continue": "Continuer",
    "Cancel": "Annuler",
    "Delete": "Supprimer",
    "Save": "Enregistrer",
    "Use": "Utiliser",
    "OK": "OK",
    "Try again": "Réessayer",
    "Refresh": "Actualiser",
    "Reset defaults": "Rétablir les valeurs par défaut",
    "On": "Activé",
    "Off": "Désactivé",
    "Automatic": "Automatique",
    "Small": "Petit",
    "Medium": "Moyen",
    "Large": "Grand",
    "Compact": "Compact",
    "Standard": "Standard",
    "Comfortable": "Confortable",
    "Cinematic": "Cinématique",
    "Home": "Accueil",
    "Search": "Rechercher",
    "My List": "Ma liste",
    "Discover": "Découvrir",
    "Calendar": "Calendrier",
    "Watch Party": "Visionnage partagé",
    "Downloads": "Téléchargements",
    "Play": "Lire",
    "Text title": "Titre en texte",
    "Title logo": "Logo du titre",
    "Top row": "Rangée supérieure",
    "Profile menu": "Menu du profil",
    "Local profiles": "Profils locaux",
    "New local profile": "Nouveau profil local",
    "Display name": "Nom affiché",
    "No local profiles yet.": "Aucun profil local pour l’instant.",
    "Select to enter a name": "Sélectionnez pour saisir un nom",
    "Select to open the TV keyboard": "Sélectionnez pour ouvrir le clavier TV",
    "Default player": "Lecteur par défaut",
    "Preferred audio": "Audio préféré",
    "Preferred audio language": "Langue audio préférée",
    "Preferred CC": "Sous-titres préférés",
    "Preferred subtitle language": "Langue de sous-titres préférée",
    "Follow Dub/Sub": "Suivre doublage/sous-titres",
    "English for Dubbed, Japanese for Subtitled":
        "Anglais en doublage, japonais en sous-titré",
    "Media3 (Built in)": "Media3 (Intégré)",
    "MPV (Built in)": "MPV (Intégré)",
    "Media3 SurfaceView": "Media3 SurfaceView",
    "External player": "Lecteur externe",
    "Auto-skip intros": "Ignorer les génériques de début",
    "Auto-skip outros": "Ignorer les génériques de fin",
    "Rewind": "Reculer",
    "Fast-forward": "Avancer",
    "Text color": "Couleur du texte",
    "Background": "Arrière-plan",
    "Text size": "Taille du texte",
    "Filler episode labels": "Indication des épisodes hors-série",
    "Debrid provider": "Fournisseur debrid",
    "Debrid streams": "Flux debrid",
    "Web streams": "Flux web",
    "Direct peer streaming": "Streaming direct entre pairs",
    "Manage sources": "Gérer les sources",
    "Debrid results": "Résultats debrid",
    "Source priority": "Priorité des sources",
    "Quality priority": "Priorité de qualité",
    "Preferred Web quality": "Qualité web préférée",
    "Automatic selection": "Sélection automatique",
    "Strict audio": "Filtrage audio strict",
    "Local, Jellyfin & Plex sources": "Sources locales, Jellyfin et Plex",
    "Offline downloads": "Téléchargements hors ligne",
    "Download manager": "Gestionnaire de téléchargements",
    "Anime-list provider": "Fournisseur de liste d’anime",
    "When to update episode progress": "Quand actualiser la progression",
    "Sub & simulcast alerts": "Alertes sous-titres et simulcast",
    "Verified dub alerts": "Alertes de doublages confirmés",
    "Discord presence": "Activité Discord",
    "Disconnect": "Déconnecter",
    "Connect Discord": "Connecter Discord",
    "Unlink Discord": "Dissocier Discord",
    "Connect by QR": "Connecter par QR",
    "Personal API token": "Jeton API personnel",
    "Personal API key": "Clé API personnelle",
    "Personal Access Token": "Jeton d’accès personnel",
    "Manual API token": "Jeton API manuel",
    "TorBox API token": "Jeton API TorBox",
    "Run setup again": "Relancer la configuration",
    "Device calibration": "Étalonnage de l’appareil",
    "Diagnostics": "Diagnostics",
    "Update channel": "Canal de mise à jour",
    "Release history": "Historique des versions",
    "Check now": "Vérifier maintenant",
    "Choose a compatible signed release":
        "Choisir une version signée compatible",
    "Privacy & data": "Confidentialité et données",
    "Third-party notices": "Mentions tierces",
    "Anonymous crash reports": "Rapports de plantage anonymes",
    "Anonymous live count": "Compteur d’activité anonyme",
    "Reset appearance and navigation": "Réinitialiser apparence et navigation",
    "Reset appearance & navigation": "Réinitialiser apparence et navigation",
    "Reset all TetoTV data?": "Effacer toutes les données TetoTV ?",
    "Erase everything": "Tout effacer",
    "Keep my data": "Garder mes données",
    "Cancel reset": "Annuler la réinitialisation",
    "Final confirmation": "Confirmation finale",
    "Support TetoTV": "Soutenir TetoTV",
    "Join the TetoTV Discord": "Rejoindre le Discord TetoTV",
    "Copy Discord invite": "Copier l’invitation Discord",
    "Discord invite copied.": "Invitation Discord copiée.",
    "Copy Ko-fi link": "Copier le lien Ko-fi",
    "Ko-fi donation link copied.": "Lien de don Ko-fi copié.",
  },
  'hi': {
    "Current {version}{latest}": "मौजूदा {version}{latest}",
    "Anonymous crash reports start enabled on new installs and are optional. Existing installs keep their current choice. You can turn them off here or anytime in Settings. Reports contain only the app/build, error type and time, Android version, CPU architecture, device class, and a redacted technical trace. They never include a show, episode, account, device ID, source, or URL.":
        "नई इंस्टॉलेशन पर अनाम क्रैश रिपोर्ट शुरू में चालू रहती हैं और वैकल्पिक हैं। मौजूदा इंस्टॉलेशन अपनी वर्तमान पसंद बनाए रखती हैं। आप इन्हें यहाँ या सेटिंग्स में कभी भी बंद कर सकते हैं। रिपोर्ट में केवल ऐप/बिल्ड, त्रुटि का प्रकार और समय, Android संस्करण, CPU आर्किटेक्चर, डिवाइस श्रेणी और संवेदनशील जानकारी हटाया तकनीकी ट्रेस होता है। इनमें कभी शो, एपिसोड, खाता, डिवाइस ID, स्रोत या URL शामिल नहीं होता।",
    "The Beta live count shares only whether TetoTV is active or has an MPV player open. It contains no profile or media details; normal HTTPS delivery and short-lived abuse limits may process an IP address, but the presence record does not store it.":
        "बीटा सक्रिय गणना केवल बताती है कि TetoTV सक्रिय है या MPV प्लेयर खुला है। इसमें प्रोफ़ाइल या मीडिया जानकारी नहीं है; HTTPS और अल्पकालिक दुरुपयोग-सीमाएँ IP संसाधित कर सकती हैं, पर गतिविधि रिकॉर्ड इसे सहेजता नहीं है।",
    "Installed version: {version}{date}": "इंस्टॉल संस्करण: {version}{date}",
    "Latest {channel}: {version}": "नवीनतम {channel}: {version}",
    "Latest {version}": "नवीनतम {version}",
    "Downloading {percent}%": "डाउनलोड हो रहा है {percent}%",
    "Loading releases…": "रिलीज़ लोड हो रही हैं…",
    "Load release history": "रिलीज़ इतिहास लोड करें",
    "Opening installer…": "इंस्टॉलर खुल रहा है…",
    "Install update": "अपडेट इंस्टॉल करें",
    "Check for updates": "अपडेट जाँचें",
    "Automatic: ON": "स्वचालित: चालू",
    "Automatic: OFF": "स्वचालित: बंद",
    "Apply theme": "थीम लागू करें",
    "Theme applied.": "थीम लागू हुई।",
    "TetoTV colors restored.": "TetoTV के रंग रीसेट हुए।",
    "Fix the contrast warnings or turn off the safeguard.":
        "कंट्रास्ट चेतावनी ठीक करें या सुरक्षा बंद करें।",
    "The readability safeguard blocked this theme.":
        "पढ़ने की सुविधा की सुरक्षा ने यह थीम रोकी।",
    "Trackers store whole completed episodes, so the selected percentage marks the current episode watched.":
        "ट्रैकर पूरे एपिसोड रिकॉर्ड करते हैं, इसलिए चुने प्रतिशत पर मौजूदा एपिसोड देखा हुआ चिह्नित होता है।",
    "Checking installed video players…":
        "इंस्टॉल वीडियो प्लेयर जाँचे जा रहे हैं…",
    "External apps can only receive safe, header-free streams. Private Plex and Jellyfin sessions stay in TetoTV.":
        "बाहरी ऐप केवल सुरक्षित, बिना हेडर वाली स्ट्रीम पाते हैं। निजी Plex और Jellyfin सत्र TetoTV में रहते हैं।",
    "Adds an Open externally action for compatible streams. Turning this off returns an external default to Media3; your built-in player choice stays selected. TetoTV never shares account headers or private-server credentials.":
        "अनुकूल स्ट्रीम में बाहरी ऐप में खोलने का विकल्प जोड़ता है। बंद करने पर बाहरी डिफ़ॉल्ट Media3 होता है; बिल्ट-इन प्लेयर की पसंद बनी रहती है। TetoTV खाते के हेडर या निजी सर्वर क्रेडेंशियल कभी साझा नहीं करता।",
    "Reorder": "क्रम बदलें",
    "English logo": "अंग्रेज़ी लोगो",
    "Copy full report": "पूरी रिपोर्ट कॉपी करें",
    "Export full report": "पूरी रिपोर्ट निर्यात करें",
    "Full redacted report copied.":
        "संवेदनशील जानकारी हटाकर पूरी रिपोर्ट कॉपी हुई।",
    "Send diagnostic report?": "डायग्नोस्टिक रिपोर्ट भेजें?",
    "Send report": "रिपोर्ट भेजें",
    "The diagnostic report could not be sent. Try again shortly.":
        "डायग्नोस्टिक रिपोर्ट नहीं भेजी जा सकी। थोड़ी देर में फिर कोशिश करें।",
    "Support report": "सहायता रिपोर्ट",
    "Recent redacted events": "हाल की गोपनीय जानकारी हटाई गई घटनाएँ",
    "Playback session timelines": "प्लेबैक सत्र की समयरेखा",
    "Started vs failed playback": "शुरू हुए और विफल प्लेबैक",
    "Started session": "शुरू हुआ सत्र",
    "Failed session": "विफल सत्र",
    "No recent playback or provider failures.":
        "हाल में प्लेबैक या प्रदाता विफलता नहीं मिली।",
    "No correlated playback sessions have been recorded yet.":
        "अभी कोई संबंधित प्लेबैक सत्र रिकॉर्ड नहीं हुआ है।",
    "A session that started and a failed session are needed before TetoTV can compare them. This is not a smooth-versus-stuttering comparison.":
        "तुलना के लिए TetoTV को एक शुरू हुआ और एक विफल सत्र चाहिए। यह सुचारु और रुक-रुककर चलने की तुलना नहीं है।",
    "Privacy-safe stages correlate source selection, stream opening, decoder choice, fallback attempts, and the final result. Media names, addresses, URLs, filenames, headers, and server IDs are never shown.":
        "गोपनीय चरण स्रोत चयन, स्ट्रीम खुलने, डिकोडर, बैकअप प्रयास और परिणाम को जोड़ते हैं। मीडिया नाम, पते, URL, फ़ाइलनाम, हेडर और सर्वर ID कभी नहीं दिखते।",
    "Started means video parameters became available, not that playback was smooth. Decoder choice is a requested policy; the full report includes sampled engine performance when available. UI frame timings describe the app interface, not video frame rate or dropped video frames.":
        "शुरू होने का मतलब वीडियो पैरामीटर मिले, सुचारु प्लेबैक नहीं। डिकोडर चयन अनुरोधित नीति है; पूरी रिपोर्ट में उपलब्ध इंजन प्रदर्शन नमूने हैं। UI फ़्रेम समय ऐप इंटरफ़ेस का है, वीडियो FPS या छूटे फ़्रेम का नहीं।",
    "A complete bounded dump of device capabilities, player health, performance timings, provider health, and the preceding 48 hours of persisted app events and crash summaries. Account identity, credentials, watch-room secrets, direct media sources, URLs, file paths, and network addresses are removed before it leaves the TV.":
        "डिवाइस क्षमता, प्लेयर स्थिति, प्रदर्शन समय, प्रदाता स्थिति और पिछले 48 घंटों की सहेजी घटनाओं व क्रैश का सीमित आकार का पूरा विवरण। टीवी से भेजने से पहले पहचान, क्रेडेंशियल, वॉच-रूम रहस्य, सीधे मीडिया स्रोत, URL, फ़ाइल पथ और नेटवर्क पते हटा दिए जाते हैं।",
    "This posts the complete bounded, redacted technical dump shown in Diagnostics to TetoTV’s private Discord support channel. It includes the app build, device capabilities, player and provider health, performance timings, and the preceding 48 hours of persisted events and crash summaries. Account identity, credentials, watch-room secrets, direct media sources, file paths, and network addresses are excluded.":
        "इससे डायग्नोस्टिक्स में दिखा पूरा, सीमित और संवेदनशील जानकारी हटाया गया तकनीकी विवरण TetoTV के निजी Discord सहायता चैनल में भेजता है। इसमें ऐप बिल्ड, डिवाइस क्षमता, प्लेयर व प्रदाता स्थिति, प्रदर्शन और पिछले 48 घंटों की घटनाएँ व क्रैश हैं। पहचान, क्रेडेंशियल, वॉच-रूम रहस्य, सीधे मीडिया स्रोत, फ़ाइल पथ और नेटवर्क पते शामिल नहीं हैं।",
    "Save recommendation": "सुझाव सहेजें",
    "Scan again": "फिर स्कैन करें",
    "Video decoders": "वीडियो डिकोडर",
    "TetoTV scans Android’s decoders, display, audio output, and subtitle engine.":
        "TetoTV Android के डिकोडर, डिस्प्ले, ऑडियो आउटपुट और उपशीर्षक इंजन स्कैन करता है।",
    "The privacy disclosure could not be loaded.":
        "गोपनीयता जानकारी लोड नहीं हो सकी।",
    "Third-party notices could not be loaded.":
        "तृतीय-पक्ष नोटिस लोड नहीं हो सके।",
    "Third-party notices document": "तृतीय-पक्ष नोटिस दस्तावेज़",
    "This device does not support resetting TetoTV.":
        "इस डिवाइस पर TetoTV रीसेट समर्थित नहीं है।",
    "This device does not support TetoTV cache cleanup.":
        "इस डिवाइस पर TetoTV कैश सफ़ाई समर्थित नहीं है।",
    "Direct torrent is unavailable": "सीधा टोरेंट उपलब्ध नहीं",
    "This build supports direct torrent playback and downloads on ARM32 and ARM64 Android devices. It is unavailable on this device architecture.":
        "यह बिल्ड ARM32 और ARM64 Android डिवाइस पर सीधे टोरेंट प्लेबैक और डाउनलोड समर्थित करता है। इस डिवाइस आर्किटेक्चर पर उपलब्ध नहीं है।",
    "Enable direct peer torrents?": "सीधे पीयर टोरेंट चालू करें?",
    "Enable direct peers": "सीधे पीयर चालू करें",
    "Keep off": "बंद रखें",
    "This connects directly to public torrent peers without a debrid account. Your public IP address is visible to peers and trackers, and selected episode data may upload while you watch or download. Streaming may use up to 6 GB of temporary storage; offline files remain until you delete them in Download Manager. Only access content you are legally allowed to use.":
        "यह debrid खाते के बिना सीधे सार्वजनिक टोरेंट पीयर से जुड़ता है। आपका सार्वजनिक IP पीयर और ट्रैकर को दिखता है; देखते या डाउनलोड करते समय एपिसोड डेटा अपलोड हो सकता है। स्ट्रीमिंग 6 GB तक अस्थायी जगह ले सकती है; ऑफ़लाइन फ़ाइलें डाउनलोड मैनेजर में हटाने तक रहती हैं। केवल कानूनी अनुमति वाला कंटेंट इस्तेमाल करें।",
    "Not installed — TetoTV will fall back to Media3":
        "इंस्टॉल नहीं है — TetoTV Media3 इस्तेमाल करेगा",
    "Offer installed video players for compatible, header-free streams.":
        "अनुकूल, बिना हेडर वाली स्ट्रीम के लिए इंस्टॉल वीडियो प्लेयर दिखाएँ।",
    "Open externally": "बाहरी ऐप में खोलें",
    "Choose which buttons are shown and move them into your preferred order. Settings can move to the profile menu, with a top-row fallback on small screens or when no profile is linked.":
        "दिखने वाले बटन और उनका क्रम चुनें। सेटिंग्स प्रोफ़ाइल मेन्यू में जा सकती हैं; छोटी स्क्रीन या बिना प्रोफ़ाइल पर ऊपर विकल्प रहेगा।",
    "Entries marked Blocked by Android remain visible for reference but cannot be selected. Android cannot replace this installation with a lower build code; Developer Mode cannot bypass that rule. A same-or-higher-code rebuild can roll back while preserving data.":
        "Android द्वारा अवरुद्ध विकल्प संदर्भ के लिए दिखते हैं, चुने नहीं जा सकते। Android कम बिल्ड कोड वाली इंस्टॉलेशन से बदल नहीं सकता; डेवलपर मोड भी इसे नहीं बदलता। समान या बड़े कोड वाला रीबिल्ड डेटा बचाकर पुरानी रिलीज़ पर लौट सकता है।",
    "Join the TetoTV Discord for announcements, support, and feature requests.":
        "घोषणाओं, सहायता और सुविधा सुझावों के लिए TetoTV Discord से जुड़ें।",
    "Scan the code with your phone, or select the invite below to copy it.":
        "फ़ोन से कोड स्कैन करें या नीचे आमंत्रण चुनकर कॉपी करें।",
    "Donations are optional. Scan with your phone to open the official TetoTV Ko-fi page, or select the link below to copy it.":
        "दान वैकल्पिक है। आधिकारिक TetoTV Ko-fi पेज खोलने के लिए फ़ोन से स्कैन करें या नीचे लिंक चुनकर कॉपी करें।",
    "Optional. When enabled, Discord can show the anime title, episode, playing or paused state, and playback timer. TetoTV never asks for or stores your Discord password.":
        "वैकल्पिक। चालू होने पर Discord शीर्षक, एपिसोड, चलने/रुकी स्थिति और समय दिखा सकता है। TetoTV आपका Discord पासवर्ड कभी नहीं माँगता या सहेजता।",
    "Development disclosure: TetoTV includes code created and reviewed with AI-assisted development tools. Releases are tested and maintained by the project owner.":
        "विकास जानकारी: TetoTV में AI-सहायता वाले टूल से बनाया और जाँचा कोड शामिल है। परियोजना मालिक रिलीज़ का परीक्षण और रखरखाव करता है।",
    "TetoTV is an independent, unofficial client. It is not affiliated with or endorsed by AniList, MAL, Kitsu, SIMKL, debrid services, addon authors, or media rights holders. Users add and are responsible for their own services and repositories.":
        "TetoTV एक स्वतंत्र, अनौपचारिक क्लाइंट है। यह AniList, MAL, Kitsu, SIMKL, debrid सेवाओं, ऐड-ऑन लेखकों या मीडिया अधिकार धारकों से संबद्ध या समर्थित नहीं है। उपयोगकर्ता अपनी सेवाएँ और रिपॉज़िटरी जोड़ते हैं और उनके लिए ज़िम्मेदार हैं।",
    "Reports may include the app version, Android version, device class, error type, time, and a redacted trace. They never include what you watch, accounts, device IDs, sources, or URLs.":
        "रिपोर्ट में ऐप व Android संस्करण, डिवाइस श्रेणी, त्रुटि प्रकार, समय और संवेदनशील जानकारी हटाया ट्रेस हो सकता है। देखे गए कंटेंट, खाते, डिवाइस ID, स्रोत या URL कभी शामिल नहीं होते।",
    "Shares only whether this Beta app process is active or has an MPV player open. A paused or loading player can still count as watching. No profile, title, episode, source, device ID, URL, or media information is sent. HTTPS and abuse limits may process your IP, but it is not stored in the presence record.":
        "केवल साझा करता है कि बीटा ऐप सक्रिय है या MPV प्लेयर खुला है। रुका या लोड होता प्लेयर भी देखने में गिना जा सकता है। प्रोफ़ाइल, शीर्षक, एपिसोड, स्रोत, डिवाइस ID, URL या मीडिया जानकारी नहीं भेजी जाती। HTTPS और दुरुपयोग-सीमा आपका IP संसाधित कर सकते हैं, लेकिन वह गतिविधि रिकॉर्ड में नहीं सहेजा जाता।",
    "{step} of {count}": "{count} में से {step}",
    "{count} selected": "{count} चुने गए",
    "{count} sources added": "{count} स्रोत जोड़े गए",
    "Delete {name}?": "{name} हटाएँ?",
    "Connected as {name}. Lists and episode progress sync automatically.":
        "{name} के रूप में कनेक्ट है। सूचियाँ और एपिसोड की प्रगति अपने आप सिंक होती हैं।",
    "Build: {number}": "बिल्ड: {number}",
    "Prefer dubbed sources. Track selection follows Preferred audio language.":
        "डब स्रोतों को प्राथमिकता दें। ट्रैक पसंदीदा ऑडियो भाषा का अनुसरण करता है।",
    "Prefer subtitled sources. Track selection follows Preferred audio language.":
        "सब स्रोतों को प्राथमिकता दें। ट्रैक पसंदीदा ऑडियो भाषा का अनुसरण करता है।",
    "Preparing secure phone setup…": "सुरक्षित फ़ोन सेटअप तैयार हो रहा है…",
    "Secure setup resumed.": "सुरक्षित सेटअप फिर शुरू हुआ।",
    "Finishing the setup already applied on this device…":
        "इस डिवाइस पर लागू सेटअप पूरा हो रहा है…",
    "Scan the QR code or enter the code on your phone.":
        "QR स्कैन करें या फ़ोन पर कोड दर्ज करें।",
    "Secure phone setup could not start. Check the connection and try again.":
        "सुरक्षित फ़ोन सेटअप शुरू नहीं हुआ। कनेक्शन जाँचें और फिर कोशिश करें।",
    "Waiting for your phone to connect…": "फ़ोन कनेक्ट होने की प्रतीक्षा है…",
    "Phone connected. Your progress is saved while you finish setup.":
        "फ़ोन कनेक्ट है। सेटअप पूरा करते समय प्रगति सहेजी जाती है।",
    "The encrypted setup did not pass validation. Review it on your phone and send it again.":
        "एन्क्रिप्टेड सेटअप सत्यापित नहीं हुआ। फ़ोन पर जाँचें और फिर भेजें।",
    "Review what will be added. Account secrets remain hidden.":
        "जो जोड़ा जाएगा उसकी समीक्षा करें। खाते की गोपनीय जानकारी छिपी रहती है।",
    "Phone setup is complete.": "फ़ोन सेटअप पूरा हुआ।",
    "The phone rejected or could not finish this setup. Try again.":
        "फ़ोन ने सेटअप अस्वीकार किया या पूरा नहीं कर पाया। फिर कोशिश करें।",
    "Connection interrupted. TetoTV will keep trying securely in the background.":
        "कनेक्शन टूट गया। TetoTV पृष्ठभूमि में सुरक्षित रूप से प्रयास करता रहेगा।",
    "Verifying accounts and applying your choices…":
        "खाते सत्यापित करके विकल्प लागू हो रहे हैं…",
    "Your choices are saved. Reconnecting to confirm completion…":
        "आपके विकल्प सहेजे गए हैं। पूरा होने की पुष्टि के लिए फिर कनेक्ट हो रहा है…",
    "Setup could not be applied. Nothing was sent back; try again.":
        "सेटअप लागू नहीं हुआ। कुछ वापस नहीं भेजा गया; फिर कोशिश करें।",
    "Returning this setup to your phone for changes…":
        "बदलाव के लिए सेटअप फ़ोन पर वापस भेजा जा रहा है…",
    "Make your changes on the phone, then send them again.":
        "फ़ोन पर बदलाव करें, फिर दोबारा भेजें।",
    "Could not return the setup yet. Try again.":
        "सेटअप अभी वापस नहीं भेजा जा सका। फिर कोशिश करें।",
    "Creating a fresh secure setup code…": "नया सुरक्षित सेटअप कोड बन रहा है…",
    "Invalidating the old code before creating a new one…":
        "नया बनाने से पहले पुराना कोड रद्द हो रहा है…",
    "A new secure setup code is ready.": "नया सुरक्षित सेटअप कोड तैयार है।",
    "The old code could not be replaced securely. Check the connection and try again.":
        "पुराना कोड सुरक्षित रूप से बदला नहीं गया। कनेक्शन जाँचें और फिर कोशिश करें।",
    "This setup session expired. Create a new secure code.":
        "इस सेटअप सत्र की समय-सीमा समाप्त हुई। नया सुरक्षित कोड बनाएँ।",
    "Protected with end-to-end encryption. You sign in only on each service's official page; TetoTV never asks for passwords. The setup companion holds the resulting credentials only temporarily, then your browser encrypts them for this device. Credentials never appear in the QR code, URL, browser draft storage, logs, or diagnostics. After your phone connects, the page can be minimized and reopened without losing the setup draft.":
        "एंड-टू-एंड एन्क्रिप्शन से सुरक्षित। आप केवल सेवा के आधिकारिक पेज पर साइन इन करते हैं; TetoTV पासवर्ड कभी नहीं माँगता। सेटअप companion क्रेडेंशियल केवल अस्थायी रूप से रखता है, फिर ब्राउज़र इन्हें इस डिवाइस के लिए एन्क्रिप्ट करता है। क्रेडेंशियल QR, URL, ब्राउज़र ड्राफ़्ट, लॉग या डायग्नोस्टिक्स में नहीं आते। फ़ोन कनेक्ट होने के बाद पेज छोटा करके फिर खोल सकते हैं, ड्राफ़्ट नहीं खोता।",
    "Make TetoTV yours": "TetoTV को अपना बनाएँ",
    "Change the app canvas, panels, focus color and text. Your saved theme is shared by phone and TV layouts.":
        "पृष्ठभूमि, पैनल, फ़ोकस रंग और टेक्स्ट बदलें। सहेजी गई थीम फ़ोन और टीवी दोनों में इस्तेमाल होती है।",
    "App colors": "ऐप के रंग",
    "Panels & surfaces": "पैनल और सतहें",
    "Accent, focus & hover": "एक्सेंट, फ़ोकस और होवर",
    "Primary text": "मुख्य टेक्स्ट",
    "Muted text": "हल्का टेक्स्ट",
    "App canvas and page backgrounds": "ऐप और पेज की पृष्ठभूमि",
    "Cards, menus and dialog panels": "कार्ड, मेन्यू और डायलॉग पैनल",
    "Selection, focus rings and primary actions":
        "चयन, फ़ोकस रिंग और मुख्य क्रियाएँ",
    "Headings and important labels": "शीर्षक और महत्वपूर्ण लेबल",
    "Descriptions and secondary labels": "विवरण और गौण लेबल",
    "Featured show": "फ़ीचर्ड शो",
    "Continue watching · Episode 7": "देखना जारी रखें · एपिसोड 7",
    "Your library": "आपकी लाइब्रेरी",
    "Panels, labels and focus states update here.":
        "पैनल, लेबल और फ़ोकस स्थिति यहाँ अपडेट होते हैं।",
    "Focused": "फ़ोकस में",
    "Protect readable contrast": "पढ़ने योग्य कंट्रास्ट रखें",
    "Prevents a theme from hiding text or TV focus rings.":
        "थीम को टेक्स्ट या टीवी फ़ोकस रिंग छिपाने से रोकता है।",
    "Low-contrast theme allowed because the safeguard is off.":
        "सुरक्षा बंद होने से कम कंट्रास्ट वाली थीम की अनुमति है।",
    "Choose a built-in color with the D-pad. Exact hex entry is available as an optional advanced choice.":
        "रिमोट से बिल्ट-इन रंग चुनें। सटीक हेक्स मान डालना एक वैकल्पिक उन्नत विकल्प है।",
    "Selected color": "चुना हुआ रंग",
    "Built-in colors": "बिल्ट-इन रंग",
    "Built-in remote color picker": "रिमोट से बिल्ट-इन रंग चयन",
    "Exact hex color": "सटीक हेक्स रंग",
    "Use color": "रंग इस्तेमाल करें",
    "Live theme preview": "थीम का लाइव पूर्वावलोकन",
    "Built-in": "बिल्ट-इन",
    "Click": "क्लिक",
    "Display": "डिस्प्ले",
    "Device": "डिवाइस",
    "App": "ऐप",
    "Privacy": "गोपनीयता",
    "Home & navigation": "होम और नेविगेशन",
    "Home content": "होम का कंटेंट",
    "Interface sounds": "इंटरफ़ेस ध्वनियाँ",
    "Featured": "फ़ीचर्ड",
    "First": "पहला",
    "Active": "सक्रिय",
    "Optional": "वैकल्पिक",
    "Connected": "कनेक्ट है",
    "Not connected": "कनेक्ट नहीं है",
    "Linked": "लिंक है",
    "Not linked": "लिंक नहीं है",
    "Disabled": "अक्षम",
    "Unavailable": "अनुपलब्ध",
    "Ready": "तैयार",
    "Reconnect": "फिर कनेक्ट करें",
    "Checking": "जाँच हो रही है",
    "Checking…": "जाँच हो रही है…",
    "Loading…": "लोड हो रहा है…",
    "Saving…": "सहेजा जा रहा है…",
    "Please wait…": "कृपया प्रतीक्षा करें…",
    "Manage": "प्रबंधित करें",
    "Create": "बनाएँ",
    "Save & verify": "सहेजें और सत्यापित करें",
    "Add profile": "प्रोफ़ाइल जोड़ें",
    "Shown": "दिखाया गया",
    "Hidden": "छिपा हुआ",
    "Discord account": "Discord खाता",
    "Discord account linked": "Discord खाता लिंक है",
    "Checking Discord": "Discord की जाँच हो रही है",
    "Unavailable on this device": "इस डिवाइस पर उपलब्ध नहीं",
    "Retry connection": "कनेक्शन फिर आज़माएँ",
    "Disable Rich Presence": "Discord गतिविधि बंद करें",
    "Enable Rich Presence": "Discord गतिविधि चालू करें",
    "Authorize TetoTV through Discord’s secure account-linking flow.":
        "Discord की सुरक्षित खाता-लिंक प्रक्रिया से TetoTV को अनुमति दें।",
    "Control whether your current playback appears on Discord.":
        "चुनें कि मौजूदा प्लेबैक Discord पर दिखे या नहीं।",
    "Turn Rich Presence back on for this linked account.":
        "इस लिंक किए खाते के लिए गतिविधि फिर चालू करें।",
    "Connect SIMKL": "SIMKL कनेक्ट करें",
    "Reconnect SIMKL": "SIMKL फिर कनेक्ट करें",
    "Reconnect SIMKL to verify this saved account.":
        "इस सहेजे खाते को सत्यापित करने के लिए SIMKL फिर कनेक्ट करें।",
    "Link SIMKL securely through its official sign-in page.":
        "आधिकारिक साइन-इन पेज से SIMKL सुरक्षित लिंक करें।",
    "SIMKL sign-in must be enabled on the TetoTV companion first.":
        "पहले TetoTV companion में SIMKL साइन-इन चालू होना चाहिए।",
    "Remove the saved SIMKL connection from TetoTV.":
        "TetoTV से सहेजा गया SIMKL कनेक्शन हटाएँ।",
    "Replace the saved connection through SIMKL’s secure sign-in.":
        "SIMKL के सुरक्षित साइन-इन से सहेजा कनेक्शन बदलें।",
    "Open the secure SIMKL authorization flow.":
        "सुरक्षित SIMKL अनुमति प्रक्रिया खोलें।",
    "Clearing cache…": "कैश हट रहा है…",
    "Clear cache": "कैश हटाएँ",
    "Resetting TetoTV…": "TetoTV रीसेट हो रहा है…",
    "Reset TetoTV": "TetoTV रीसेट करें",
    "Currently installed": "अभी इंस्टॉल है",
    "Same build number • package and signature checked before install":
        "समान बिल्ड नंबर • इंस्टॉल से पहले पैकेज और हस्ताक्षर जाँचे जाएँगे",
    "Older release • Android build compatibility checked before download":
        "पुरानी रिलीज़ • डाउनलोड से पहले Android बिल्ड अनुकूलता जाँची जाएगी",
    "Newer release • package and signature checked before install":
        "नई रिलीज़ • इंस्टॉल से पहले पैकेज और हस्ताक्षर जाँचे जाएँगे",
    "Not reported": "जानकारी नहीं दी गई",
    "Developer update tools": "डेवलपर अपडेट टूल",
    "History enabled": "इतिहास चालू है",
    "Switch channels or inspect signed release history. Android only installs the same or a higher build code.":
        "चैनल बदलें या हस्ताक्षरित रिलीज़ इतिहास देखें। Android केवल समान या बड़े बिल्ड कोड इंस्टॉल करता है।",
    "Choose Public or Beta. Beta builds may be less stable.":
        "Public या Beta चुनें। Beta बिल्ड कम स्थिर हो सकते हैं।",
    "Secure updates ready": "सुरक्षित अपडेट तैयार हैं",
    "What’s new": "नया क्या है",
    "Creating a secure session": "सुरक्षित सत्र बन रहा है",
    "Waiting for your phone": "आपके फ़ोन की प्रतीक्षा है",
    "Phone connected": "फ़ोन कनेक्ट है",
    "Review before applying": "लागू करने से पहले समीक्षा करें",
    "Applying securely": "सुरक्षित रूप से लागू हो रहा है",
    "Setup complete": "सेटअप पूरा हुआ",
    "Code expired": "कोड की समय-सीमा समाप्त",
    "Setup unavailable": "सेटअप उपलब्ध नहीं",
    "Selected account": "चुना हुआ खाता",
    "Selected service": "चुनी हुई सेवा",
    "Preferences": "पसंद",
    "Marketplace repositories": "Marketplace रिपॉज़िटरी",
    "Torrent manifests": "टोरेंट मैनिफ़ेस्ट",
    "Debrid service": "Debrid सेवा",
    "Authorized securely": "सुरक्षित अनुमति मिली",
    "Connect after setup": "सेटअप के बाद कनेक्ट करें",
    "Skip": "छोड़ें",
    "How would you like to set up TetoTV?":
        "आप TetoTV कैसे सेट अप करना चाहेंगे?",
    "Choose the setup method that works best for you.":
        "अपना पसंदीदा सेटअप तरीका चुनें।",
    "You can adjust these choices later in Settings.":
        "इन विकल्पों को बाद में सेटिंग्स में बदल सकते हैं।",
    "Preparing setup…": "सेटअप तैयार हो रहा है…",
    "First-run setup": "पहला सेटअप",
    "Setup on device": "इस डिवाइस पर सेटअप",
    "Setup on another device": "दूसरे डिवाइस पर सेटअप",
    "Simple on-device setup": "डिवाइस पर आसान सेटअप",
    "Phone-friendly setup": "फ़ोन से आसान सेटअप",
    "Simple D-pad setup": "रिमोट से आसान सेटअप",
    "Optimized for touch": "टच के लिए अनुकूलित",
    "Complete every setup step directly on this device.":
        "सेटअप के सभी चरण इसी डिवाइस पर पूरे करें।",
    "Use a phone, tablet, or computer while this device stays on the setup screen.":
        "इस डिवाइस को सेटअप स्क्रीन पर रखकर फ़ोन, टैबलेट या कंप्यूटर का इस्तेमाल करें।",
    "Leave setup?": "सेटअप छोड़ें?",
    "You can finish these choices later from Settings.":
        "इन विकल्पों को बाद में सेटिंग्स में पूरा कर सकते हैं।",
    "Keep setting up": "सेटअप जारी रखें",
    "Set up later": "बाद में सेटअप करें",
    "Set up TetoTV": "TetoTV सेट अप करें",
    "Choose your playback defaults": "अपनी डिफ़ॉल्ट प्लेबैक पसंद चुनें",
    "Set your language, subtitles, input, and skipping.":
        "भाषा, उपशीर्षक, इनपुट और स्किप सेट करें।",
    "Audio & subtitle default": "डिफ़ॉल्ट ऑडियो और उपशीर्षक",
    "Anime title language": "एनीमे शीर्षक की भाषा",
    "Text input": "टेक्स्ट इनपुट",
    "TetoTV keyboard": "TetoTV कीबोर्ड",
    "Device keyboard": "डिवाइस का कीबोर्ड",
    "On-screen keyboard": "ऑन-स्क्रीन कीबोर्ड",
    "Automatic skipping": "स्वचालित स्किप",
    "Skip intros": "इंट्रो छोड़ें",
    "Skip outros": "आउट्रो छोड़ें",
    "Connect your accounts": "अपने खाते कनेक्ट करें",
    "Sync your watchlist and Discord presence, or skip either one.":
        "अपनी सूची और Discord गतिविधि सिंक करें, या किसी को भी छोड़ दें।",
    "Anime list": "एनीमे सूची",
    "Connections are optional. TetoTV never sees or stores your account passwords.":
        "कनेक्शन वैकल्पिक हैं। TetoTV आपके खाते के पासवर्ड कभी नहीं देखता या सहेजता।",
    "Set up streaming": "स्ट्रीमिंग सेट अप करें",
    "Connect providers and choose how episode sources are found.":
        "प्रदाता कनेक्ट करें और एपिसोड के स्रोत खोजने का तरीका चुनें।",
    "Choose a debrid provider if you use one. Connecting it now is optional.":
        "यदि इस्तेमाल करते हैं तो debrid प्रदाता चुनें। अभी कनेक्ट करना वैकल्पिक है।",
    "Your sources": "आपके स्रोत",
    "Add only repositories and manifests you trust and are authorized to use. TetoTV does not bundle or recommend sources.":
        "केवल भरोसेमंद रिपॉज़िटरी और मैनिफ़ेस्ट जोड़ें जिनके उपयोग की आपको अनुमति है। TetoTV स्रोत शामिल या सुझाता नहीं है।",
    "Add sources with phone": "फ़ोन से स्रोत जोड़ें",
    "Open Marketplace manually": "Marketplace मैन्युअल रूप से खोलें",
    "One last choice": "एक अंतिम विकल्प",
    "Allow error reports": "त्रुटि रिपोर्ट की अनुमति दें",
    "Do not send": "न भेजें",
    "Anonymous crash and error reports": "अनाम क्रैश और त्रुटि रिपोर्ट",
    "Anonymous Beta live count": "अनाम बीटा सक्रिय संख्या",
    "Count me in": "मुझे शामिल करें",
    "Opt out": "शामिल न करें",
    "Set up with phone": "फ़ोन से सेटअप करें",
    "One secure setup for accounts, Discord, sources, debrid, and preferences":
        "खाते, Discord, स्रोत, debrid और पसंद के लिए एक सुरक्षित सेटअप",
    "Connect your phone": "अपना फ़ोन कनेक्ट करें",
    "Open secure setup page": "सुरक्षित सेटअप पेज खोलें",
    "Match this on both screens": "दोनों स्क्रीन पर इसका मिलान करें",
    "Edit on phone": "फ़ोन पर संपादित करें",
    "Apply setup": "सेटअप लागू करें",
    "Start TetoTV": "TetoTV शुरू करें",
    "Regenerate code": "नया कोड बनाएँ",
    "Set up on this device instead": "इसके बजाय इसी डिवाइस पर सेटअप करें",
    "Use on-device setup instead": "इसके बजाय डिवाइस पर सेटअप करें",
    "No browser could open the secure setup page.":
        "कोई ब्राउज़र सुरक्षित सेटअप पेज नहीं खोल पाया।",
    "Account credentials are end-to-end encrypted and intentionally hidden from this preview. Linked services use their official authorization pages; passwords are never included.":
        "खाते के क्रेडेंशियल एंड-टू-एंड एन्क्रिप्टेड हैं और इस पूर्वावलोकन में छिपे हैं। सेवाएँ अपने आधिकारिक अनुमति पेज इस्तेमाल करती हैं; पासवर्ड कभी शामिल नहीं होते।",
    "Anime tracking connected": "एनीमे ट्रैकिंग कनेक्ट है",
    "Discord connected": "Discord कनेक्ट है",
    "Debrid service connected": "Debrid सेवा कनेक्ट है",
    "Encrypted setup verified": "एन्क्रिप्टेड सेटअप सत्यापित है",
    "Preferences saved": "पसंद सहेजी गईं",
    "Navigation & logo size": "नेविगेशन और लोगो का आकार",
    "Navigation bar": "नेविगेशन बार",
    "Home layout": "होम लेआउट",
    "Home details": "होम की जानकारी",
    "Poster badges": "पोस्टर बैज",
    "Finish": "पूरा करें",
    "Choose how Home looks and keep your everyday shortcuts close.":
        "होम की दिखावट चुनें और रोज़मर्रा के शॉर्टकट पास रखें।",
    "Modern Layout": "आधुनिक लेआउट",
    "Classic Layout (retired)": "क्लासिक लेआउट (हटाया गया)",
    "After 50%": "50% के बाद",
    "After 75%": "75% के बाद",
    "After 90%": "90% के बाद",
    "At episode end": "एपिसोड के अंत में",
    "Mark the episode watched once half of it has played.":
        "आधा एपिसोड चलने के बाद देखा हुआ चिह्नित करें।",
    "Mark the episode watched after three quarters has played.":
        "तीन-चौथाई चलने के बाद देखा हुआ चिह्नित करें।",
    "Mark the episode watched near the end (recommended).":
        "अंत के पास देखा हुआ चिह्नित करें (अनुशंसित)।",
    "Only mark the episode watched after playback finishes.":
        "प्लेबैक समाप्त होने पर ही देखा हुआ चिह्नित करें।",
    "Use the preferred language when captions are needed.":
        "उपशीर्षक की ज़रूरत होने पर पसंदीदा भाषा इस्तेमाल करें।",
    "Start captions on when a matching track is available.":
        "मेल खाने वाला ट्रैक उपलब्ध होने पर उपशीर्षक चालू करें।",
    "Start playback with captions off.": "उपशीर्षक बंद रखकर प्लेबैक शुरू करें।",
    "Any": "कोई भी",
    "Debrid only": "केवल debrid",
    "Web only": "केवल वेब",
    "Use the preferred source order": "पसंदीदा स्रोत क्रम इस्तेमाल करें",
    "Automatically select cached releases":
        "कैश में उपलब्ध रिलीज़ अपने आप चुनें",
    "Automatically select Web streams": "वेब स्ट्रीम अपने आप चुनें",
    "Local library": "लोकल लाइब्रेरी",
    "Cached torrent and debrid releases": "कैश किए गए टोरेंट और debrid रिलीज़",
    "Marketplace Web streams": "Marketplace वेब स्ट्रीम",
    "Exact episode matches from local, Jellyfin, or Plex libraries":
        "लोकल, Jellyfin या Plex लाइब्रेरी के सटीक मिलान वाले एपिसोड",
    "Allow every available resolution": "सभी उपलब्ध रिज़ॉल्यूशन की अनुमति दें",
    "Dub only": "केवल डब",
    "Sub only": "केवल सब",
    "Allow dubbed or subtitled streams": "डब या सब स्ट्रीम की अनुमति दें",
    "Require English audio support": "अंग्रेज़ी ऑडियो समर्थन आवश्यक",
    "Require original audio support": "मूल ऑडियो समर्थन आवश्यक",
    "TetoTV built-in player": "TetoTV बिल्ट-इन प्लेयर",
    "Built-in Android player with TetoTV controls":
        "TetoTV नियंत्रणों वाला बिल्ट-इन Android प्लेयर",
    "A selected app installed on this device":
        "इस डिवाइस पर इंस्टॉल किया गया चुना हुआ ऐप",
    "Personalize TetoTV, the Home screen, navigation, and feedback.":
        "TetoTV, होम स्क्रीन, नेविगेशन और प्रतिक्रिया को अपनी पसंद दें।",
    "Customize colors and preview the TetoTV interface.":
        "रंग बदलें और TetoTV इंटरफ़ेस का पूर्वावलोकन देखें।",
    "Choose what appears on Home and move favorites toward the top.":
        "होम पर क्या दिखे चुनें और पसंदीदा सेक्शन ऊपर लाएँ।",
    "Choose audio, skipping, seeking, and playback behavior.":
        "ऑडियो, स्किप, सीक और प्लेबैक व्यवहार चुनें।",
    "Tune captions, player behavior, audio, skipping, and seeking.":
        "उपशीर्षक, प्लेयर, ऑडियो, स्किप और सीक समायोजित करें।",
    "Style subtitles for comfortable viewing on every screen.":
        "हर स्क्रीन पर आराम से पढ़ने के लिए उपशीर्षक की शैली बदलें।",
    "Compatibility engine with full TetoTV controls":
        "सभी TetoTV नियंत्रणों वाला संगतता इंजन",
    "Default Android engine with the same TetoTV controls":
        "उन्हीं TetoTV नियंत्रणों वाला डिफ़ॉल्ट Android प्लेबैक इंजन",
    "SurfaceView (default). Media3 only; applies to the next video.":
        "SurfaceView (डिफ़ॉल्ट)। केवल Media3; अगले वीडियो पर लागू होगा।",
    "TextureView. Turn on to restore the default SurfaceView renderer and select Media3 for the next video.":
        "TextureView। डिफ़ॉल्ट SurfaceView रेंडरर बहाल करने और अगले वीडियो के लिए Media3 चुनने हेतु इसे चालू करें।",
    "Skip detected opening segments automatically.":
        "पहचाने गए शुरुआती हिस्से अपने आप छोड़ें।",
    "Skip detected ending segments automatically.":
        "पहचाने गए अंतिम हिस्से अपने आप छोड़ें।",
    "Mark episodes identified as anime-original filler.":
        "एनीमे-ओरिजिनल फ़िलर के रूप में पहचाने गए एपिसोड चिह्नित करें।",
    "Play feedback while moving between controls.":
        "नियंत्रणों के बीच जाते समय ध्वनि चलाएँ।",
    "Play confirmation feedback when selecting an option.":
        "विकल्प चुनने पर पुष्टि की ध्वनि चलाएँ।",
    "Show supporting text beneath posters and media cards.":
        "पोस्टर और मीडिया कार्ड के नीचे अतिरिक्त टेक्स्ट दिखाएँ।",
    "Choose and securely connect the provider used to resolve streams.":
        "स्ट्रीम उपलब्ध कराने वाला प्रदाता चुनें और सुरक्षित रूप से कनेक्ट करें।",
    "Choose which source types are searched and how results are ranked.":
        "खोजे जाने वाले स्रोत प्रकार और परिणामों का क्रम चुनें।",
    "Use cached and resolved streams from your linked service.":
        "अपनी कनेक्ट की गई सेवा की कैश और उपलब्ध स्ट्रीम इस्तेमाल करें।",
    "Include streams supplied by installed web addons.":
        "इंस्टॉल किए गए वेब ऐड-ऑन की स्ट्रीम शामिल करें।",
    "Play torrent releases directly without a debrid service.":
        "Debrid सेवा के बिना सीधे टोरेंट चलाएँ।",
    "Install, remove, and organize streaming addons.":
        "स्ट्रीमिंग ऐड-ऑन इंस्टॉल, हटाएँ और व्यवस्थित करें।",
    "Choose the highest-ranked playable source automatically.":
        "सबसे ऊँची रैंक वाला चलने योग्य स्रोत अपने आप चुनें।",
    "Prioritize source type, quality, and audio when TetoTV chooses for you.":
        "स्वचालित चयन में स्रोत प्रकार, गुणवत्ता और ऑडियो की प्राथमिकता तय करें।",
    "Preferences change ranking only. Other usable streams remain available for manual choice and automatic failover.":
        "पसंद केवल क्रम बदलती है। अन्य चलने योग्य स्ट्रीम मैन्युअल चयन और स्वचालित बैकअप के लिए उपलब्ध रहती हैं।",
    "TetoTV tries each source class from top to bottom.":
        "TetoTV ऊपर से नीचे हर स्रोत प्रकार आज़माता है।",
    "The first available quality in this order is selected.":
        "इस क्रम में पहली उपलब्ध गुणवत्ता चुनी जाती है।",
    "Manage local libraries, Watch Party, and offline viewing.":
        "लोकल लाइब्रेरी, वॉच पार्टी और ऑफ़लाइन देखना प्रबंधित करें।",
    "Connect libraries and add local files that appear in the normal source picker.":
        "लाइब्रेरी कनेक्ट करें और सामान्य स्रोत चयन में दिखने वाली लोकल फ़ाइलें जोड़ें।",
    "Review active jobs, saved episodes, and device storage.":
        "सक्रिय काम, सहेजे गए एपिसोड और डिवाइस स्टोरेज देखें।",
    "Control privacy-sensitive source and playback behavior.":
        "गोपनीयता से जुड़े स्रोत और प्लेबैक व्यवहार नियंत्रित करें।",
    "Profiles, anime tracking, notifications, and linked services.":
        "प्रोफ़ाइल, एनीमे ट्रैकिंग, सूचनाएँ और कनेक्ट की गई सेवाएँ।",
    "Connect a list provider and keep episode progress synchronized.":
        "सूची प्रदाता कनेक्ट करें और एपिसोड की प्रगति सिंक रखें।",
    "Sync Kitsu lists, episode progress, and status securely.":
        "Kitsu सूचियाँ, एपिसोड प्रगति और स्थिति सुरक्षित रूप से सिंक करें।",
    "Manage local viewers and their separate preferences.":
        "लोकल दर्शक और उनकी अलग-अलग पसंद प्रबंधित करें।",
    "Create, switch, or remove names stored locally on this device.":
        "इस डिवाइस पर सहेजे गए नाम बनाएँ, बदलें या हटाएँ।",
    "Names are stored only on this device and never include tracker credentials. The selected name is shared with Watch Party participants.":
        "नाम केवल इस डिवाइस पर सहेजे जाते हैं और ट्रैकर क्रेडेंशियल शामिल नहीं करते। चुना हुआ नाम वॉच पार्टी के प्रतिभागियों से साझा होता है।",
    "This removes only the local profile name. Shared history, settings, and connected trackers stay saved.":
        "इससे केवल लोकल प्रोफ़ाइल नाम हटता है। साझा इतिहास, सेटिंग्स और कनेक्ट किए गए ट्रैकर सहेजे रहते हैं।",
    "Choose when progress syncs and which episode alerts appear.":
        "प्रगति कब सिंक हो और कौन-सी एपिसोड सूचना दिखे चुनें।",
    "Notify when a subtitled or simulcast episode reaches its normal airtime.":
        "सब या सिमुलकास्ट एपिसोड के सामान्य प्रसारण समय पर सूचना दें।",
    "Notify only when a dubbed episode has a verified release schedule.":
        "डब एपिसोड का सत्यापित रिलीज़ समय होने पर ही सूचना दें।",
    "Control the optional Discord activity shown while you watch.":
        "देखते समय दिखने वाली वैकल्पिक Discord गतिविधि नियंत्रित करें।",
    "Remove this Discord connection from TetoTV on this device.":
        "इस डिवाइस के TetoTV से यह Discord कनेक्शन हटाएँ।",
    "Manage this device, updates, diagnostics, privacy, storage, and legal information.":
        "डिवाइस, अपडेट, डायग्नोस्टिक्स, गोपनीयता, स्टोरेज और कानूनी जानकारी प्रबंधित करें।",
    "Setup, device compatibility, calibration, and diagnostics.":
        "सेटअप, डिवाइस अनुकूलता, कैलिब्रेशन और डायग्नोस्टिक्स।",
    "Change setup method or reconnect your services.":
        "सेटअप का तरीका बदलें या अपनी सेवाएँ फिर कनेक्ट करें।",
    "Adjust display fit, input, and playback compatibility.":
        "डिस्प्ले फ़िट, इनपुट और प्लेबैक अनुकूलता समायोजित करें।",
    "Review system health and export troubleshooting details.":
        "सिस्टम की स्थिति देखें और समस्या-समाधान की जानकारी निर्यात करें।",
    "Stable public releases download directly to this device.":
        "स्थिर सार्वजनिक रिलीज़ सीधे इस डिवाइस पर डाउनलोड होती हैं।",
    "Download signed updates automatically when a newer build is available.":
        "नया बिल्ड उपलब्ध होने पर हस्ताक्षरित अपडेट अपने आप डाउनलोड करें।",
    "Check this channel and open Android’s installer when the package is ready.":
        "इस चैनल की जाँच करें और पैकेज तैयार होने पर Android इंस्टॉलर खोलें।",
    "Fetch the signed release list for the selected update channel.":
        "चुने गए अपडेट चैनल की हस्ताक्षरित रिलीज़ सूची लाएँ।",
    "Signed releases download securely from the official TetoTV repository.":
        "हस्ताक्षरित रिलीज़ आधिकारिक TetoTV रिपॉज़िटरी से सुरक्षित डाउनलोड होती हैं।",
    "Remove temporary files or return TetoTV to first-time setup.":
        "अस्थायी फ़ाइलें हटाएँ या TetoTV को शुरुआती सेटअप पर लौटाएँ।",
    "Remove temporary images, playback cache, and update leftovers. Accounts and settings stay saved.":
        "अस्थायी चित्र, प्लेबैक कैश और अपडेट के अवशेष हटाएँ। खाते और सेटिंग्स सहेजे रहते हैं।",
    "Erase accounts, preferences, sources, and history, then return to first-time setup.":
        "खाते, पसंद, स्रोत और इतिहास मिटाकर शुरुआती सेटअप पर लौटें।",
    "Privacy, attribution, and open-source notices.":
        "गोपनीयता, श्रेय और ओपन-सोर्स नोटिस।",
    "Review what TetoTV stores, processes, and shares.":
        "देखें TetoTV क्या सहेजता, संसाधित और साझा करता है।",
    "Read attribution and open-source license notices.":
        "श्रेय और ओपन-सोर्स लाइसेंस नोटिस पढ़ें।",
    "Control optional privacy-safe reporting and Beta activity signals.":
        "वैकल्पिक गोपनीय रिपोर्टिंग और बीटा गतिविधि संकेत नियंत्रित करें।",
    "Review the optional privacy controls used by this build.":
        "इस बिल्ड के वैकल्पिक गोपनीयता नियंत्रण देखें।",
    "Send a redacted technical report after an unexpected crash.":
        "अचानक क्रैश के बाद संवेदनशील जानकारी हटाई गई तकनीकी रिपोर्ट भेजें।",
    "Include this device in the privacy-safe Beta activity count.":
        "इस डिवाइस को गोपनीय बीटा गतिविधि गणना में शामिल करें।",
    "Validate and save this credential securely.":
        "इस क्रेडेंशियल को सत्यापित करके सुरक्षित सहेजें।",
    "Open the secure device authorization flow.":
        "सुरक्षित डिवाइस अनुमति प्रक्रिया खोलें।",
    "Open TorBox device authorization.": "TorBox डिवाइस अनुमति खोलें।",
    "Remove the saved Real-Debrid connection.":
        "सहेजा गया Real-Debrid कनेक्शन हटाएँ।",
    "Remove the saved TorBox connection.": "सहेजा गया TorBox कनेक्शन हटाएँ।",
    "Choose your language": "अपनी भाषा चुनें",
    "This sets the app language and preferred audio and captions. You can change them separately later.":
        "इससे ऐप की भाषा और पसंदीदा ऑडियो व उपशीर्षक सेट होते हैं। बाद में इन्हें अलग-अलग बदल सकते हैं।",
    "Also sets preferred audio and captions. You can change them separately in Playback.":
        "पसंदीदा ऑडियो और उपशीर्षक भी सेट करता है। इन्हें प्लेबैक में अलग-अलग बदल सकते हैं।",
    "App language": "ऐप की भाषा",
    "Appearance": "दिखावट",
    "Playback": "प्लेबैक",
    "Services": "सेवाएँ",
    "Accounts": "खाते",
    "System": "सिस्टम",
    "Settings": "सेटिंग्स",
    "Theme & display": "थीम और डिस्प्ले",
    "Theme Studio": "थीम स्टूडियो",
    "Title language": "शीर्षक की भाषा",
    "Show title style": "शीर्षक शैली",
    "Colors": "रंग",
    "Home screen": "होम स्क्रीन",
    "Featured hero": "मुख्य फ़ीचर्ड बैनर",
    "Poster metadata": "पोस्टर की जानकारी",
    "Continue watching": "देखना जारी रखें",
    "Display options": "डिस्प्ले विकल्प",
    "Interface scale": "इंटरफ़ेस का आकार",
    "Content density": "कंटेंट का घनत्व",
    "Thumbnail size": "थंबनेल का आकार",
    "Layout style": "लेआउट शैली",
    "Default landing page": "डिफ़ॉल्ट शुरुआती पेज",
    "Card details": "कार्ड की जानकारी",
    "Input & feedback": "इनपुट और प्रतिक्रिया",
    "Home shelves": "होम सेक्शन",
    "Navigation": "नेविगेशन",
    "Navigation size": "नेविगेशन का आकार",
    "Menu order": "मेन्यू का क्रम",
    "Navigation sounds": "नेविगेशन ध्वनियाँ",
    "Click sounds": "क्लिक की ध्वनियाँ",
    "Closed captions": "उपशीर्षक",
    "Player controls": "प्लेयर नियंत्रण",
    "Debrid streaming": "Debrid स्ट्रीमिंग",
    "Sources & stream order": "स्रोत और स्ट्रीम क्रम",
    "Automatic source selection": "स्वचालित स्रोत चयन",
    "Libraries & features": "लाइब्रेरी और सुविधाएँ",
    "Streaming privacy": "स्ट्रीमिंग गोपनीयता",
    "Anime tracking": "एनीमे ट्रैकिंग",
    "Profiles": "प्रोफ़ाइल",
    "Progress & notifications": "प्रगति और सूचनाएँ",
    "Discord Rich Presence": "Discord गतिविधि",
    "Device & support": "डिवाइस और सहायता",
    "App updates": "ऐप अपडेट",
    "Community": "समुदाय",
    "Storage & reset": "स्टोरेज और रीसेट",
    "About & legal": "परिचय और कानूनी जानकारी",
    "Privacy & diagnostics": "गोपनीयता और डायग्नोस्टिक्स",
    "Search settings": "सेटिंग्स खोजें",
    "No matching settings": "कोई सेटिंग नहीं मिली",
    "No matching settings found": "कोई मेल खाती सेटिंग नहीं मिली",
    "Expand all": "सभी खोलें",
    "Collapse all": "सभी समेटें",
    "Back": "वापस",
    "Close": "बंद करें",
    "Continue": "जारी रखें",
    "Cancel": "रद्द करें",
    "Delete": "हटाएँ",
    "Save": "सहेजें",
    "Use": "इस्तेमाल करें",
    "OK": "ठीक है",
    "Try again": "फिर कोशिश करें",
    "Refresh": "रीफ़्रेश करें",
    "Reset defaults": "डिफ़ॉल्ट रीसेट करें",
    "On": "चालू",
    "Off": "बंद",
    "Automatic": "स्वचालित",
    "Small": "छोटा",
    "Medium": "मध्यम",
    "Large": "बड़ा",
    "Compact": "कॉम्पैक्ट",
    "Standard": "मानक",
    "Comfortable": "आरामदायक",
    "Cinematic": "सिनेमैटिक",
    "Home": "होम",
    "Search": "खोजें",
    "My List": "मेरी सूची",
    "Discover": "खोजबीन",
    "Calendar": "कैलेंडर",
    "Watch Party": "वॉच पार्टी",
    "Downloads": "डाउनलोड",
    "Play": "चलाएँ",
    "Text title": "टेक्स्ट शीर्षक",
    "Title logo": "शीर्षक का लोगो",
    "Top row": "ऊपरी पंक्ति",
    "Profile menu": "प्रोफ़ाइल मेन्यू",
    "Local profiles": "लोकल प्रोफ़ाइल",
    "New local profile": "नई लोकल प्रोफ़ाइल",
    "Display name": "दिखने वाला नाम",
    "No local profiles yet.": "अभी कोई लोकल प्रोफ़ाइल नहीं है।",
    "Select to enter a name": "नाम दर्ज करने के लिए चुनें",
    "Select to open the TV keyboard": "टीवी कीबोर्ड खोलने के लिए चुनें",
    "Default player": "डिफ़ॉल्ट प्लेयर",
    "Preferred audio": "पसंदीदा ऑडियो",
    "Preferred audio language": "पसंदीदा ऑडियो भाषा",
    "Preferred CC": "पसंदीदा उपशीर्षक",
    "Preferred subtitle language": "पसंदीदा उपशीर्षक भाषा",
    "Follow Dub/Sub": "डब/सब का अनुसरण करें",
    "English for Dubbed, Japanese for Subtitled":
        "डब के लिए अंग्रेज़ी, सब के लिए जापानी",
    "Media3 (Built in)": "Media3 (बिल्ट-इन)",
    "MPV (Built in)": "MPV (बिल्ट-इन)",
    "Media3 SurfaceView": "Media3 SurfaceView",
    "External player": "बाहरी प्लेयर",
    "Auto-skip intros": "इंट्रो अपने आप छोड़ें",
    "Auto-skip outros": "आउट्रो अपने आप छोड़ें",
    "Rewind": "पीछे करें",
    "Fast-forward": "आगे करें",
    "Text color": "टेक्स्ट का रंग",
    "Background": "पृष्ठभूमि",
    "Text size": "टेक्स्ट का आकार",
    "Filler episode labels": "फ़िलर एपिसोड के लेबल",
    "Debrid provider": "Debrid प्रदाता",
    "Debrid streams": "Debrid स्ट्रीम",
    "Web streams": "वेब स्ट्रीम",
    "Direct peer streaming": "सीधे पीयर से स्ट्रीमिंग",
    "Manage sources": "स्रोत प्रबंधित करें",
    "Debrid results": "Debrid परिणाम",
    "Source priority": "स्रोत की प्राथमिकता",
    "Quality priority": "गुणवत्ता की प्राथमिकता",
    "Preferred Web quality": "पसंदीदा वेब गुणवत्ता",
    "Automatic selection": "स्वचालित चयन",
    "Strict audio": "सख्त ऑडियो फ़िल्टर",
    "Local, Jellyfin & Plex sources": "लोकल, Jellyfin और Plex स्रोत",
    "Offline downloads": "ऑफ़लाइन डाउनलोड",
    "Download manager": "डाउनलोड मैनेजर",
    "Anime-list provider": "एनीमे-सूची प्रदाता",
    "When to update episode progress": "एपिसोड की प्रगति कब अपडेट हो",
    "Sub & simulcast alerts": "सब और सिमुलकास्ट सूचनाएँ",
    "Verified dub alerts": "पुष्ट डब सूचनाएँ",
    "Discord presence": "Discord गतिविधि",
    "Disconnect": "डिस्कनेक्ट करें",
    "Connect Discord": "Discord कनेक्ट करें",
    "Unlink Discord": "Discord अनलिंक करें",
    "Connect by QR": "QR से कनेक्ट करें",
    "Personal API token": "व्यक्तिगत API टोकन",
    "Personal API key": "व्यक्तिगत API कुंजी",
    "Personal Access Token": "व्यक्तिगत एक्सेस टोकन",
    "Manual API token": "मैन्युअल API टोकन",
    "TorBox API token": "TorBox API टोकन",
    "Run setup again": "सेटअप फिर से चलाएँ",
    "Device calibration": "डिवाइस कैलिब्रेशन",
    "Diagnostics": "डायग्नोस्टिक्स",
    "Update channel": "अपडेट चैनल",
    "Release history": "रिलीज़ इतिहास",
    "Check now": "अभी जाँचें",
    "Choose a compatible signed release": "अनुकूल हस्ताक्षरित रिलीज़ चुनें",
    "Privacy & data": "गोपनीयता और डेटा",
    "Third-party notices": "तृतीय-पक्ष नोटिस",
    "Anonymous crash reports": "अनाम क्रैश रिपोर्ट",
    "Anonymous live count": "अनाम सक्रिय संख्या",
    "Reset appearance and navigation": "दिखावट और नेविगेशन रीसेट करें",
    "Reset appearance & navigation": "दिखावट और नेविगेशन रीसेट करें",
    "Reset all TetoTV data?": "TetoTV का सारा डेटा रीसेट करें?",
    "Erase everything": "सब मिटाएँ",
    "Keep my data": "मेरा डेटा रखें",
    "Cancel reset": "रीसेट रद्द करें",
    "Final confirmation": "अंतिम पुष्टि",
    "Support TetoTV": "TetoTV का समर्थन करें",
    "Join the TetoTV Discord": "TetoTV Discord से जुड़ें",
    "Copy Discord invite": "Discord आमंत्रण कॉपी करें",
    "Discord invite copied.": "Discord आमंत्रण कॉपी हो गया।",
    "Copy Ko-fi link": "Ko-fi लिंक कॉपी करें",
    "Ko-fi donation link copied.": "Ko-fi दान लिंक कॉपी हो गया।",
  },
  'de': {
    "Current {version}{latest}": "Aktuell {version}{latest}",
    "Anonymous crash reports start enabled on new installs and are optional. Existing installs keep their current choice. You can turn them off here or anytime in Settings. Reports contain only the app/build, error type and time, Android version, CPU architecture, device class, and a redacted technical trace. They never include a show, episode, account, device ID, source, or URL.":
        "Anonyme Absturzberichte sind bei neuen Installationen zunächst aktiviert und optional. Bestehende Installationen behalten ihre aktuelle Auswahl. Du kannst sie hier oder jederzeit in den Einstellungen ausschalten. Berichte enthalten nur App/Build, Fehlertyp und Zeitpunkt, Android-Version, CPU-Architektur, Geräteklasse und einen bereinigten technischen Trace. Sie enthalten niemals Serie, Folge, Konto, Geräte-ID, Quelle oder URL.",
    "The Beta live count shares only whether TetoTV is active or has an MPV player open. It contains no profile or media details; normal HTTPS delivery and short-lived abuse limits may process an IP address, but the presence record does not store it.":
        "Die Beta-Aktivitätszählung teilt nur mit, ob TetoTV aktiv oder ein MPV-Player geöffnet ist. Keine Profil- oder Mediendetails; HTTPS und kurzzeitiger Missbrauchsschutz können eine IP verarbeiten, der Aktivitätseintrag speichert sie jedoch nicht.",
    "Installed version: {version}{date}":
        "Installierte Version: {version}{date}",
    "Latest {channel}: {version}": "Neueste {channel}: {version}",
    "Latest {version}": "Neueste {version}",
    "Downloading {percent}%": "Download {percent} %",
    "Loading releases…": "Versionen werden geladen…",
    "Load release history": "Versionsverlauf laden",
    "Opening installer…": "Installer wird geöffnet…",
    "Install update": "Update installieren",
    "Check for updates": "Nach Updates suchen",
    "Automatic: ON": "Automatisch: EIN",
    "Automatic: OFF": "Automatisch: AUS",
    "Apply theme": "Design anwenden",
    "Theme applied.": "Design angewendet.",
    "TetoTV colors restored.": "TetoTV-Farben wiederhergestellt.",
    "Fix the contrast warnings or turn off the safeguard.":
        "Kontrastwarnungen beheben oder Schutz ausschalten.",
    "The readability safeguard blocked this theme.":
        "Der Lesbarkeitsschutz hat dieses Design blockiert.",
    "Trackers store whole completed episodes, so the selected percentage marks the current episode watched.":
        "Tracker speichern vollständige Folgen; beim gewählten Prozentsatz gilt die aktuelle Folge als gesehen.",
    "Checking installed video players…":
        "Installierte Videoplayer werden geprüft…",
    "External apps can only receive safe, header-free streams. Private Plex and Jellyfin sessions stay in TetoTV.":
        "Externe Apps erhalten nur sichere Streams ohne Header. Private Plex- und Jellyfin-Sitzungen bleiben in TetoTV.",
    "Adds an Open externally action for compatible streams. Turning this off returns an external default to Media3; your built-in player choice stays selected. TetoTV never shares account headers or private-server credentials.":
        "Fügt Extern öffnen für kompatible Streams hinzu. Ausschalten setzt einen externen Standard auf Media3 zurück; deine integrierte Playerwahl bleibt erhalten. TetoTV teilt nie Konto-Header oder private Serverzugangsdaten.",
    "Reorder": "Neu anordnen",
    "English logo": "Englisches Logo",
    "Copy full report": "Vollständigen Bericht kopieren",
    "Export full report": "Vollständigen Bericht exportieren",
    "Full redacted report copied.":
        "Vollständiger bereinigter Bericht kopiert.",
    "Send diagnostic report?": "Diagnosebericht senden?",
    "Send report": "Bericht senden",
    "The diagnostic report could not be sent. Try again shortly.":
        "Der Diagnosebericht konnte nicht gesendet werden. Versuche es gleich erneut.",
    "Support report": "Supportbericht",
    "Recent redacted events": "Letzte bereinigte Ereignisse",
    "Playback session timelines": "Wiedergabesitzungsverlauf",
    "Started vs failed playback": "Gestartete und fehlgeschlagene Wiedergaben",
    "Started session": "Gestartete Sitzung",
    "Failed session": "Fehlgeschlagene Sitzung",
    "No recent playback or provider failures.":
        "Keine aktuellen Wiedergabe- oder Anbieterfehler.",
    "No correlated playback sessions have been recorded yet.":
        "Noch keine zugeordneten Wiedergabesitzungen aufgezeichnet.",
    "A session that started and a failed session are needed before TetoTV can compare them. This is not a smooth-versus-stuttering comparison.":
        "TetoTV benötigt eine gestartete und eine fehlgeschlagene Sitzung zum Vergleich. Das ist kein Vergleich zwischen flüssiger und ruckelnder Wiedergabe.",
    "Privacy-safe stages correlate source selection, stream opening, decoder choice, fallback attempts, and the final result. Media names, addresses, URLs, filenames, headers, and server IDs are never shown.":
        "Datensparsame Phasen verknüpfen Quellenauswahl, Streamöffnung, Decoderwahl, Ersatzversuche und Ergebnis. Mediennamen, Adressen, URLs, Dateinamen, Header und Server-IDs werden nie angezeigt.",
    "Started means video parameters became available, not that playback was smooth. Decoder choice is a requested policy; the full report includes sampled engine performance when available. UI frame timings describe the app interface, not video frame rate or dropped video frames.":
        "Gestartet bedeutet verfügbare Videoparameter, nicht flüssige Wiedergabe. Die Decoderwahl ist die angeforderte Strategie; der vollständige Bericht enthält verfügbare Leistungsmessungen. UI-Framezeiten betreffen die Oberfläche, nicht Video-FPS oder verlorene Videoframes.",
    "A complete bounded dump of device capabilities, player health, performance timings, provider health, and the preceding 48 hours of persisted app events and crash summaries. Account identity, credentials, watch-room secrets, direct media sources, URLs, file paths, and network addresses are removed before it leaves the TV.":
        "Vollständiger, größenbegrenzter Bericht zu Gerätefähigkeiten, Player, Leistung, Anbietern und gespeicherten Ereignissen und Abstürzen der letzten 48 Stunden. Kontoidentität, Zugangsdaten, Raumgeheimnisse, direkte Medienquellen, URLs, Dateipfade und Netzwerkadressen werden vor Verlassen des TVs entfernt.",
    "This posts the complete bounded, redacted technical dump shown in Diagnostics to TetoTV’s private Discord support channel. It includes the app build, device capabilities, player and provider health, performance timings, and the preceding 48 hours of persisted events and crash summaries. Account identity, credentials, watch-room secrets, direct media sources, file paths, and network addresses are excluded.":
        "Sendet den vollständigen, begrenzten und bereinigten Diagnosebericht an TetoTVs privaten Discord-Supportkanal. Enthalten sind App-Build, Gerätefähigkeiten, Player- und Anbieterzustand, Leistung sowie Ereignisse und Abstürze der letzten 48 Stunden. Kontoidentität, Zugangsdaten, Raumgeheimnisse, direkte Medienquellen, Dateipfade und Netzwerkadressen sind ausgeschlossen.",
    "Save recommendation": "Empfehlung speichern",
    "Scan again": "Erneut prüfen",
    "Video decoders": "Videodecoder",
    "TetoTV scans Android’s decoders, display, audio output, and subtitle engine.":
        "TetoTV prüft Androids Decoder, Display, Audioausgabe und Untertitel-Engine.",
    "The privacy disclosure could not be loaded.":
        "Die Datenschutzhinweise konnten nicht geladen werden.",
    "Third-party notices could not be loaded.":
        "Drittanbieterhinweise konnten nicht geladen werden.",
    "Third-party notices document": "Dokument mit Drittanbieterhinweisen",
    "This device does not support resetting TetoTV.":
        "Dieses Gerät unterstützt das Zurücksetzen von TetoTV nicht.",
    "This device does not support TetoTV cache cleanup.":
        "Dieses Gerät unterstützt das Leeren des TetoTV-Caches nicht.",
    "Direct torrent is unavailable": "Direkte Torrents nicht verfügbar",
    "This build supports direct torrent playback and downloads on ARM32 and ARM64 Android devices. It is unavailable on this device architecture.":
        "Dieser Build unterstützt direkte Torrent-Wiedergabe und Downloads auf ARM32- und ARM64-Android-Geräten. Für diese Gerätearchitektur ist das nicht verfügbar.",
    "Enable direct peer torrents?": "Direkte Peer-Torrents aktivieren?",
    "Enable direct peers": "Direkte Peers aktivieren",
    "Keep off": "Ausgeschaltet lassen",
    "This connects directly to public torrent peers without a debrid account. Your public IP address is visible to peers and trackers, and selected episode data may upload while you watch or download. Streaming may use up to 6 GB of temporary storage; offline files remain until you delete them in Download Manager. Only access content you are legally allowed to use.":
        "Verbindet direkt mit öffentlichen Torrent-Peers ohne Debrid-Konto. Deine öffentliche IP ist für Peers und Tracker sichtbar; beim Ansehen oder Laden können Folgendaten hochgeladen werden. Streaming kann bis zu 6 GB temporären Speicher nutzen; Offline-Dateien bleiben bis zur Löschung im Download-Manager. Nutze nur rechtmäßig zugängliche Inhalte.",
    "Not installed — TetoTV will fall back to Media3":
        "Nicht installiert – TetoTV verwendet ersatzweise Media3",
    "Offer installed video players for compatible, header-free streams.":
        "Installierte Videoplayer für kompatible Streams ohne Header anbieten.",
    "Open externally": "Extern öffnen",
    "Choose which buttons are shown and move them into your preferred order. Settings can move to the profile menu, with a top-row fallback on small screens or when no profile is linked.":
        "Wähle sichtbare Schaltflächen und ihre Reihenfolge. Einstellungen können ins Profilmenü verschoben werden; auf kleinen Bildschirmen oder ohne Profil bleiben sie oben erreichbar.",
    "Entries marked Blocked by Android remain visible for reference but cannot be selected. Android cannot replace this installation with a lower build code; Developer Mode cannot bypass that rule. A same-or-higher-code rebuild can roll back while preserving data.":
        "Als von Android blockiert markierte Einträge bleiben sichtbar, sind aber nicht wählbar. Android erlaubt keinen niedrigeren Build-Code; der Entwicklermodus umgeht das nicht. Ein Neubuild mit gleichem oder höherem Code ermöglicht eine Rückkehr unter Beibehaltung der Daten.",
    "Join the TetoTV Discord for announcements, support, and feature requests.":
        "Tritt TetoTV-Discord für Ankündigungen, Support und Funktionswünsche bei.",
    "Scan the code with your phone, or select the invite below to copy it.":
        "Scanne den Code mit dem Smartphone oder wähle die Einladung unten zum Kopieren.",
    "Donations are optional. Scan with your phone to open the official TetoTV Ko-fi page, or select the link below to copy it.":
        "Spenden sind freiwillig. Scanne mit dem Smartphone für die offizielle TetoTV-Ko-fi-Seite oder wähle den Link unten zum Kopieren.",
    "Optional. When enabled, Discord can show the anime title, episode, playing or paused state, and playback timer. TetoTV never asks for or stores your Discord password.":
        "Optional. Discord kann Anime-Titel, Folge, Wiedergabe- oder Pausenstatus und Zeit anzeigen. TetoTV fragt niemals nach deinem Discord-Passwort und speichert es nicht.",
    "Development disclosure: TetoTV includes code created and reviewed with AI-assisted development tools. Releases are tested and maintained by the project owner.":
        "Entwicklungshinweis: TetoTV enthält mit KI-gestützten Werkzeugen erstellten und geprüften Code. Versionen werden vom Projektinhaber getestet und gepflegt.",
    "TetoTV is an independent, unofficial client. It is not affiliated with or endorsed by AniList, MAL, Kitsu, SIMKL, debrid services, addon authors, or media rights holders. Users add and are responsible for their own services and repositories.":
        "TetoTV ist ein unabhängiger, inoffizieller Client, ohne Verbindung zu oder Unterstützung durch AniList, MAL, Kitsu, SIMKL, Debrid-Dienste, Add-on-Autoren oder Rechteinhaber. Nutzer fügen eigene Dienste und Repositorys hinzu und sind dafür verantwortlich.",
    "Reports may include the app version, Android version, device class, error type, time, and a redacted trace. They never include what you watch, accounts, device IDs, sources, or URLs.":
        "Berichte können App- und Android-Version, Geräteklasse, Fehlertyp, Zeitpunkt und bereinigten Trace enthalten. Niemals enthalten sind angesehene Inhalte, Konten, Geräte-IDs, Quellen oder URLs.",
    "Shares only whether this Beta app process is active or has an MPV player open. A paused or loading player can still count as watching. No profile, title, episode, source, device ID, URL, or media information is sent. HTTPS and abuse limits may process your IP, but it is not stored in the presence record.":
        "Teilt nur mit, ob der Beta-App-Prozess aktiv oder ein MPV-Player geöffnet ist. Pausieren oder Laden kann als Anschauen zählen. Keine Profile, Titel, Folgen, Quellen, Geräte-IDs, URLs oder Mediendaten werden gesendet. HTTPS und Missbrauchsschutz können deine IP verarbeiten, speichern sie aber nicht im Aktivitätseintrag.",
    "{step} of {count}": "{step} von {count}",
    "{count} selected": "{count} ausgewählt",
    "{count} sources added": "{count} Quellen hinzugefügt",
    "Delete {name}?": "{name} löschen?",
    "Connected as {name}. Lists and episode progress sync automatically.":
        "Verbunden als {name}. Listen und Folgenfortschritt werden automatisch synchronisiert.",
    "Build: {number}": "Build: {number}",
    "Prefer dubbed sources. Track selection follows Preferred audio language.":
        "Synchronisierte Quellen bevorzugen. Die Spur folgt der bevorzugten Audiosprache.",
    "Prefer subtitled sources. Track selection follows Preferred audio language.":
        "Untertitelte Quellen bevorzugen. Die Spur folgt der bevorzugten Audiosprache.",
    "Preparing secure phone setup…":
        "Sichere Smartphone-Einrichtung wird vorbereitet…",
    "Secure setup resumed.": "Sichere Einrichtung fortgesetzt.",
    "Finishing the setup already applied on this device…":
        "Bereits übernommene Einrichtung wird abgeschlossen…",
    "Scan the QR code or enter the code on your phone.":
        "Scanne den QR-Code oder gib den Code auf deinem Smartphone ein.",
    "Secure phone setup could not start. Check the connection and try again.":
        "Sichere Smartphone-Einrichtung konnte nicht starten. Verbindung prüfen und erneut versuchen.",
    "Waiting for your phone to connect…":
        "Warte auf die Smartphone-Verbindung…",
    "Phone connected. Your progress is saved while you finish setup.":
        "Smartphone verbunden. Dein Fortschritt wird während der Einrichtung gespeichert.",
    "The encrypted setup did not pass validation. Review it on your phone and send it again.":
        "Die verschlüsselte Einrichtung wurde nicht validiert. Auf dem Smartphone prüfen und erneut senden.",
    "Review what will be added. Account secrets remain hidden.":
        "Prüfe die Ergänzungen. Kontogeheimnisse bleiben verborgen.",
    "Phone setup is complete.": "Smartphone-Einrichtung abgeschlossen.",
    "The phone rejected or could not finish this setup. Try again.":
        "Das Smartphone hat die Einrichtung abgelehnt oder nicht abgeschlossen. Erneut versuchen.",
    "Connection interrupted. TetoTV will keep trying securely in the background.":
        "Verbindung unterbrochen. TetoTV versucht es im Hintergrund sicher weiter.",
    "Verifying accounts and applying your choices…":
        "Konten werden geprüft und deine Auswahl übernommen…",
    "Your choices are saved. Reconnecting to confirm completion…":
        "Deine Auswahl ist gespeichert. Verbindung wird zur Bestätigung wiederhergestellt…",
    "Setup could not be applied. Nothing was sent back; try again.":
        "Einrichtung konnte nicht übernommen werden. Nichts wurde zurückgesendet; erneut versuchen.",
    "Returning this setup to your phone for changes…":
        "Einrichtung wird zur Bearbeitung an dein Smartphone zurückgegeben…",
    "Make your changes on the phone, then send them again.":
        "Ändere die Auswahl auf dem Smartphone und sende sie erneut.",
    "Could not return the setup yet. Try again.":
        "Einrichtung konnte noch nicht zurückgegeben werden. Erneut versuchen.",
    "Creating a fresh secure setup code…":
        "Neuer sicherer Einrichtungscode wird erstellt…",
    "Invalidating the old code before creating a new one…":
        "Alter Code wird vor Erstellung eines neuen ungültig gemacht…",
    "A new secure setup code is ready.":
        "Neuer sicherer Einrichtungscode bereit.",
    "The old code could not be replaced securely. Check the connection and try again.":
        "Alter Code konnte nicht sicher ersetzt werden. Verbindung prüfen und erneut versuchen.",
    "This setup session expired. Create a new secure code.":
        "Diese Einrichtungssitzung ist abgelaufen. Erstelle einen neuen sicheren Code.",
    "Protected with end-to-end encryption. You sign in only on each service's official page; TetoTV never asks for passwords. The setup companion holds the resulting credentials only temporarily, then your browser encrypts them for this device. Credentials never appear in the QR code, URL, browser draft storage, logs, or diagnostics. After your phone connects, the page can be minimized and reopened without losing the setup draft.":
        "Ende-zu-Ende-verschlüsselt. Du meldest dich nur auf der offiziellen Seite jedes Dienstes an; TetoTV fragt nie nach Passwörtern. Der Companion hält Zugangsdaten nur vorübergehend, dann verschlüsselt dein Browser sie für dieses Gerät. Sie erscheinen nie in QR-Code, URL, Browserentwurf, Logs oder Diagnose. Nach Smartphone-Verbindung kannst du die Seite minimieren und ohne Entwurfsverlust erneut öffnen.",
    "Make TetoTV yours": "Gestalte dein TetoTV",
    "Change the app canvas, panels, focus color and text. Your saved theme is shared by phone and TV layouts.":
        "Ändere Hintergrund, Bereiche, Fokusfarbe und Text. Dein gespeichertes Design gilt für Smartphone und TV.",
    "App colors": "App-Farben",
    "Panels & surfaces": "Bereiche und Flächen",
    "Accent, focus & hover": "Akzent, Fokus und Hover",
    "Primary text": "Haupttext",
    "Muted text": "Dezenter Text",
    "App canvas and page backgrounds": "App- und Seitenhintergründe",
    "Cards, menus and dialog panels": "Karten, Menüs und Dialogbereiche",
    "Selection, focus rings and primary actions":
        "Auswahl, Fokusringe und Hauptaktionen",
    "Headings and important labels":
        "Überschriften und wichtige Beschriftungen",
    "Descriptions and secondary labels":
        "Beschreibungen und Nebenbeschriftungen",
    "Featured show": "Hervorgehobene Serie",
    "Continue watching · Episode 7": "Weiterschauen · Folge 7",
    "Your library": "Deine Bibliothek",
    "Panels, labels and focus states update here.":
        "Bereiche, Beschriftungen und Fokuszustände werden hier aktualisiert.",
    "Focused": "Fokussiert",
    "Protect readable contrast": "Lesbaren Kontrast schützen",
    "Prevents a theme from hiding text or TV focus rings.":
        "Verhindert, dass ein Design Text oder TV-Fokusringe unkenntlich macht.",
    "Low-contrast theme allowed because the safeguard is off.":
        "Kontrastarmes Design erlaubt, da der Schutz ausgeschaltet ist.",
    "Choose a built-in color with the D-pad. Exact hex entry is available as an optional advanced choice.":
        "Wähle eine integrierte Farbe per Steuerkreuz. Exakte Hex-Eingabe ist als erweiterte Option verfügbar.",
    "Selected color": "Ausgewählte Farbe",
    "Built-in colors": "Integrierte Farben",
    "Built-in remote color picker": "Integrierte Farbauswahl per Fernbedienung",
    "Exact hex color": "Exakte Hex-Farbe",
    "Use color": "Farbe verwenden",
    "Live theme preview": "Live-Designvorschau",
    "Built-in": "Integriert",
    "Click": "Klick",
    "Display": "Anzeige",
    "Device": "Gerät",
    "App": "App",
    "Privacy": "Datenschutz",
    "Home & navigation": "Startseite und Navigation",
    "Home content": "Startseiteninhalt",
    "Interface sounds": "Oberflächentöne",
    "Featured": "Hervorgehoben",
    "First": "Erste",
    "Active": "Aktiv",
    "Optional": "Optional",
    "Connected": "Verbunden",
    "Not connected": "Nicht verbunden",
    "Linked": "Verknüpft",
    "Not linked": "Nicht verknüpft",
    "Disabled": "Deaktiviert",
    "Unavailable": "Nicht verfügbar",
    "Ready": "Bereit",
    "Reconnect": "Erneut verbinden",
    "Checking": "Prüfung läuft",
    "Checking…": "Wird geprüft…",
    "Loading…": "Wird geladen…",
    "Saving…": "Wird gespeichert…",
    "Please wait…": "Bitte warten…",
    "Manage": "Verwalten",
    "Create": "Erstellen",
    "Save & verify": "Speichern und prüfen",
    "Add profile": "Profil hinzufügen",
    "Shown": "Sichtbar",
    "Hidden": "Ausgeblendet",
    "Discord account": "Discord-Konto",
    "Discord account linked": "Discord-Konto verknüpft",
    "Checking Discord": "Discord wird geprüft",
    "Unavailable on this device": "Auf diesem Gerät nicht verfügbar",
    "Retry connection": "Verbindung erneut versuchen",
    "Disable Rich Presence": "Discord-Aktivität deaktivieren",
    "Enable Rich Presence": "Discord-Aktivität aktivieren",
    "Authorize TetoTV through Discord’s secure account-linking flow.":
        "Autorisiere TetoTV über Discords sichere Kontoverknüpfung.",
    "Control whether your current playback appears on Discord.":
        "Steuere, ob deine aktuelle Wiedergabe auf Discord erscheint.",
    "Turn Rich Presence back on for this linked account.":
        "Discord-Aktivität für dieses verknüpfte Konto wieder aktivieren.",
    "Connect SIMKL": "SIMKL verbinden",
    "Reconnect SIMKL": "SIMKL erneut verbinden",
    "Reconnect SIMKL to verify this saved account.":
        "Verbinde SIMKL erneut, um dieses gespeicherte Konto zu prüfen.",
    "Link SIMKL securely through its official sign-in page.":
        "SIMKL sicher über seine offizielle Anmeldeseite verknüpfen.",
    "SIMKL sign-in must be enabled on the TetoTV companion first.":
        "Die SIMKL-Anmeldung muss zuerst im TetoTV-Companion aktiviert werden.",
    "Remove the saved SIMKL connection from TetoTV.":
        "Gespeicherte SIMKL-Verbindung aus TetoTV entfernen.",
    "Replace the saved connection through SIMKL’s secure sign-in.":
        "Gespeicherte Verbindung über SIMKLs sichere Anmeldung ersetzen.",
    "Open the secure SIMKL authorization flow.":
        "Sichere SIMKL-Autorisierung öffnen.",
    "Clearing cache…": "Cache wird geleert…",
    "Clear cache": "Cache leeren",
    "Resetting TetoTV…": "TetoTV wird zurückgesetzt…",
    "Reset TetoTV": "TetoTV zurücksetzen",
    "Currently installed": "Aktuell installiert",
    "Same build number • package and signature checked before install":
        "Gleiche Build-Nummer • Paket und Signatur werden vor Installation geprüft",
    "Older release • Android build compatibility checked before download":
        "Ältere Version • Android-Build-Kompatibilität wird vor Download geprüft",
    "Newer release • package and signature checked before install":
        "Neuere Version • Paket und Signatur werden vor Installation geprüft",
    "Not reported": "Nicht gemeldet",
    "Developer update tools": "Entwickler-Update-Werkzeuge",
    "History enabled": "Verlauf aktiviert",
    "Switch channels or inspect signed release history. Android only installs the same or a higher build code.":
        "Wechsle Kanäle oder prüfe signierte Versionen. Android installiert nur gleiche oder höhere Build-Codes.",
    "Choose Public or Beta. Beta builds may be less stable.":
        "Wähle Öffentlich oder Beta. Beta-Versionen können weniger stabil sein.",
    "Secure updates ready": "Sichere Updates bereit",
    "What’s new": "Neuigkeiten",
    "Creating a secure session": "Sichere Sitzung wird erstellt",
    "Waiting for your phone": "Warte auf dein Smartphone",
    "Phone connected": "Smartphone verbunden",
    "Review before applying": "Vor Übernahme prüfen",
    "Applying securely": "Wird sicher übernommen",
    "Setup complete": "Einrichtung abgeschlossen",
    "Code expired": "Code abgelaufen",
    "Setup unavailable": "Einrichtung nicht verfügbar",
    "Selected account": "Ausgewähltes Konto",
    "Selected service": "Ausgewählter Dienst",
    "Preferences": "Einstellungen",
    "Marketplace repositories": "Marketplace-Repositorys",
    "Torrent manifests": "Torrent-Manifeste",
    "Debrid service": "Debrid-Dienst",
    "Authorized securely": "Sicher autorisiert",
    "Connect after setup": "Nach Einrichtung verbinden",
    "Skip": "Überspringen",
    "How would you like to set up TetoTV?":
        "Wie möchtest du TetoTV einrichten?",
    "Choose the setup method that works best for you.":
        "Wähle die Einrichtungsmethode, die dir am besten passt.",
    "You can adjust these choices later in Settings.":
        "Du kannst diese Auswahl später in den Einstellungen ändern.",
    "Preparing setup…": "Einrichtung wird vorbereitet…",
    "First-run setup": "Ersteinrichtung",
    "Setup on device": "Auf diesem Gerät einrichten",
    "Setup on another device": "Auf einem anderen Gerät einrichten",
    "Simple on-device setup": "Einfache Einrichtung auf dem Gerät",
    "Phone-friendly setup": "Einrichtung per Smartphone",
    "Simple D-pad setup": "Einfache Einrichtung per Steuerkreuz",
    "Optimized for touch": "Für Touchbedienung optimiert",
    "Complete every setup step directly on this device.":
        "Führe alle Einrichtungsschritte direkt auf diesem Gerät aus.",
    "Use a phone, tablet, or computer while this device stays on the setup screen.":
        "Nutze ein Smartphone, Tablet oder einen Computer, während dieses Gerät den Einrichtungsbildschirm anzeigt.",
    "Leave setup?": "Einrichtung verlassen?",
    "You can finish these choices later from Settings.":
        "Du kannst diese Auswahl später in den Einstellungen abschließen.",
    "Keep setting up": "Einrichtung fortsetzen",
    "Set up later": "Später einrichten",
    "Set up TetoTV": "TetoTV einrichten",
    "Choose your playback defaults": "Wähle deine Wiedergabestandards",
    "Set your language, subtitles, input, and skipping.":
        "Lege Sprache, Untertitel, Eingabe und Überspringen fest.",
    "Audio & subtitle default": "Audio- und Untertitelstandard",
    "Anime title language": "Sprache der Anime-Titel",
    "Text input": "Texteingabe",
    "TetoTV keyboard": "TetoTV-Tastatur",
    "Device keyboard": "Gerätetastatur",
    "On-screen keyboard": "Bildschirmtastatur",
    "Automatic skipping": "Automatisches Überspringen",
    "Skip intros": "Intros überspringen",
    "Skip outros": "Outros überspringen",
    "Connect your accounts": "Verbinde deine Konten",
    "Sync your watchlist and Discord presence, or skip either one.":
        "Synchronisiere deine Liste und Discord-Aktivität oder überspringe eines davon.",
    "Anime list": "Anime-Liste",
    "Connections are optional. TetoTV never sees or stores your account passwords.":
        "Verbindungen sind optional. TetoTV sieht oder speichert niemals deine Kontopasswörter.",
    "Set up streaming": "Streaming einrichten",
    "Connect providers and choose how episode sources are found.":
        "Verbinde Anbieter und lege fest, wie Folgenquellen gesucht werden.",
    "Choose a debrid provider if you use one. Connecting it now is optional.":
        "Wähle einen Debrid-Anbieter, falls du einen nutzt. Die Verbindung ist jetzt optional.",
    "Your sources": "Deine Quellen",
    "Add only repositories and manifests you trust and are authorized to use. TetoTV does not bundle or recommend sources.":
        "Füge nur vertrauenswürdige Repositorys und Manifeste hinzu, die du nutzen darfst. TetoTV bündelt oder empfiehlt keine Quellen.",
    "Add sources with phone": "Quellen per Smartphone hinzufügen",
    "Open Marketplace manually": "Marketplace manuell öffnen",
    "One last choice": "Eine letzte Auswahl",
    "Allow error reports": "Fehlerberichte erlauben",
    "Do not send": "Nicht senden",
    "Anonymous crash and error reports": "Anonyme Absturz- und Fehlerberichte",
    "Anonymous Beta live count": "Anonyme Beta-Aktivitätszählung",
    "Count me in": "Mich mitzählen",
    "Opt out": "Nicht teilnehmen",
    "Set up with phone": "Per Smartphone einrichten",
    "One secure setup for accounts, Discord, sources, debrid, and preferences":
        "Eine sichere Einrichtung für Konten, Discord, Quellen, Debrid und Einstellungen",
    "Connect your phone": "Verbinde dein Smartphone",
    "Open secure setup page": "Sichere Einrichtungsseite öffnen",
    "Match this on both screens": "Auf beiden Bildschirmen vergleichen",
    "Edit on phone": "Auf dem Smartphone bearbeiten",
    "Apply setup": "Einrichtung übernehmen",
    "Start TetoTV": "TetoTV starten",
    "Regenerate code": "Neuen Code erzeugen",
    "Set up on this device instead": "Stattdessen auf diesem Gerät einrichten",
    "Use on-device setup instead": "Stattdessen Geräteeinrichtung nutzen",
    "No browser could open the secure setup page.":
        "Kein Browser konnte die sichere Einrichtungsseite öffnen.",
    "Account credentials are end-to-end encrypted and intentionally hidden from this preview. Linked services use their official authorization pages; passwords are never included.":
        "Zugangsdaten sind Ende-zu-Ende-verschlüsselt und in dieser Vorschau verborgen. Dienste verwenden ihre offiziellen Freigabeseiten; Passwörter werden nie einbezogen.",
    "Anime tracking connected": "Anime-Verfolgung verbunden",
    "Discord connected": "Discord verbunden",
    "Debrid service connected": "Debrid-Dienst verbunden",
    "Encrypted setup verified": "Verschlüsselte Einrichtung bestätigt",
    "Preferences saved": "Einstellungen gespeichert",
    "Navigation & logo size": "Navigations- und Logogröße",
    "Navigation bar": "Navigationsleiste",
    "Home layout": "Startseitenlayout",
    "Home details": "Startseitendetails",
    "Poster badges": "Poster-Abzeichen",
    "Finish": "Fertig",
    "Choose how Home looks and keep your everyday shortcuts close.":
        "Gestalte deine Startseite und halte häufige Verknüpfungen griffbereit.",
    "Modern Layout": "Modernes Layout",
    "Classic Layout (retired)": "Klassisches Layout (eingestellt)",
    "After 50%": "Nach 50 %",
    "After 75%": "Nach 75 %",
    "After 90%": "Nach 90 %",
    "At episode end": "Am Folgenende",
    "Mark the episode watched once half of it has played.":
        "Folge nach der Hälfte als gesehen markieren.",
    "Mark the episode watched after three quarters has played.":
        "Folge nach drei Vierteln als gesehen markieren.",
    "Mark the episode watched near the end (recommended).":
        "Folge kurz vor dem Ende als gesehen markieren (empfohlen).",
    "Only mark the episode watched after playback finishes.":
        "Erst nach Wiedergabeende als gesehen markieren.",
    "Use the preferred language when captions are needed.":
        "Bevorzugte Sprache verwenden, wenn Untertitel nötig sind.",
    "Start captions on when a matching track is available.":
        "Untertitel aktivieren, wenn eine passende Spur verfügbar ist.",
    "Start playback with captions off.": "Wiedergabe ohne Untertitel starten.",
    "Any": "Beliebig",
    "Debrid only": "Nur Debrid",
    "Web only": "Nur Web",
    "Use the preferred source order": "Bevorzugte Quellenreihenfolge verwenden",
    "Automatically select cached releases":
        "Gecachte Veröffentlichungen automatisch auswählen",
    "Automatically select Web streams": "Web-Streams automatisch auswählen",
    "Local library": "Lokale Bibliothek",
    "Cached torrent and debrid releases":
        "Gecachte Torrent- und Debrid-Veröffentlichungen",
    "Marketplace Web streams": "Marketplace-Web-Streams",
    "Exact episode matches from local, Jellyfin, or Plex libraries":
        "Genau passende Folgen aus lokalen, Jellyfin- oder Plex-Bibliotheken",
    "Allow every available resolution": "Alle verfügbaren Auflösungen erlauben",
    "Dub only": "Nur Dub",
    "Sub only": "Nur Sub",
    "Allow dubbed or subtitled streams":
        "Synchronisierte oder untertitelte Streams erlauben",
    "Require English audio support": "Englische Audiospur erforderlich",
    "Require original audio support": "Originalton erforderlich",
    "TetoTV built-in player": "Integrierter TetoTV-Player",
    "Built-in Android player with TetoTV controls":
        "Integrierter Android-Player mit TetoTV-Steuerung",
    "A selected app installed on this device":
        "Eine ausgewählte, auf diesem Gerät installierte App",
    "Personalize TetoTV, the Home screen, navigation, and feedback.":
        "Passe TetoTV, Startseite, Navigation und Feedback an.",
    "Customize colors and preview the TetoTV interface.":
        "Passe Farben an und sieh dir die TetoTV-Oberfläche an.",
    "Choose what appears on Home and move favorites toward the top.":
        "Wähle die Startseiteninhalte und verschiebe Favoriten nach oben.",
    "Choose audio, skipping, seeking, and playback behavior.":
        "Lege Audio, Überspringen, Spulen und Wiedergabeverhalten fest.",
    "Tune captions, player behavior, audio, skipping, and seeking.":
        "Passe Untertitel, Player, Audio, Überspringen und Spulen an.",
    "Style subtitles for comfortable viewing on every screen.":
        "Gestalte Untertitel für angenehmes Lesen auf jedem Bildschirm.",
    "Compatibility engine with full TetoTV controls":
        "Kompatibilitäts-Engine mit allen TetoTV-Steuerungen",
    "Default Android engine with the same TetoTV controls":
        "Standardmäßige Android-Wiedergabe-Engine mit denselben TetoTV-Steuerungen",
    "SurfaceView (default). Media3 only; applies to the next video.":
        "SurfaceView (Standard). Nur Media3; gilt ab dem nächsten Video.",
    "TextureView. Turn on to restore the default SurfaceView renderer and select Media3 for the next video.":
        "TextureView. Aktivieren, um SurfaceView als Standard-Renderer wiederherzustellen und Media3 für das nächste Video auszuwählen.",
    "Skip detected opening segments automatically.":
        "Erkannte Intros automatisch überspringen.",
    "Skip detected ending segments automatically.":
        "Erkannte Outros automatisch überspringen.",
    "Mark episodes identified as anime-original filler.":
        "Als animeeigene Filler erkannte Folgen markieren.",
    "Play feedback while moving between controls.":
        "Beim Wechsel zwischen Bedienelementen Töne abspielen.",
    "Play confirmation feedback when selecting an option.":
        "Bei Optionsauswahl einen Bestätigungston abspielen.",
    "Show supporting text beneath posters and media cards.":
        "Zusatztext unter Postern und Medienkarten anzeigen.",
    "Choose and securely connect the provider used to resolve streams.":
        "Wähle und verbinde sicher den Anbieter zur Streamauflösung.",
    "Choose which source types are searched and how results are ranked.":
        "Lege Quellentypen für die Suche und die Ergebnisreihenfolge fest.",
    "Use cached and resolved streams from your linked service.":
        "Gecachte und aufgelöste Streams deines verbundenen Dienstes nutzen.",
    "Include streams supplied by installed web addons.":
        "Streams installierter Web-Add-ons einbeziehen.",
    "Play torrent releases directly without a debrid service.":
        "Torrents direkt ohne Debrid-Dienst abspielen.",
    "Install, remove, and organize streaming addons.":
        "Streaming-Add-ons installieren, entfernen und ordnen.",
    "Choose the highest-ranked playable source automatically.":
        "Die höchstbewertete abspielbare Quelle automatisch auswählen.",
    "Prioritize source type, quality, and audio when TetoTV chooses for you.":
        "Bei automatischer Auswahl Quellentyp, Qualität und Audio priorisieren.",
    "Preferences change ranking only. Other usable streams remain available for manual choice and automatic failover.":
        "Die Einstellungen ändern nur die Reihenfolge. Andere nutzbare Streams bleiben zur manuellen Auswahl und als automatischer Ersatz verfügbar.",
    "TetoTV tries each source class from top to bottom.":
        "TetoTV versucht jeden Quellentyp von oben nach unten.",
    "The first available quality in this order is selected.":
        "Die erste verfügbare Qualität in dieser Reihenfolge wird gewählt.",
    "Manage local libraries, Watch Party, and offline viewing.":
        "Verwalte lokale Bibliotheken, Watch Party und Offline-Wiedergabe.",
    "Connect libraries and add local files that appear in the normal source picker.":
        "Verbinde Bibliotheken und füge lokale Dateien zur normalen Quellenauswahl hinzu.",
    "Review active jobs, saved episodes, and device storage.":
        "Aktive Aufträge, gespeicherte Folgen und Gerätespeicher prüfen.",
    "Control privacy-sensitive source and playback behavior.":
        "Datenschutzrelevantes Quellen- und Wiedergabeverhalten steuern.",
    "Profiles, anime tracking, notifications, and linked services.":
        "Profile, Anime-Verfolgung, Benachrichtigungen und verbundene Dienste.",
    "Connect a list provider and keep episode progress synchronized.":
        "Verbinde einen Listenanbieter und synchronisiere den Folgenfortschritt.",
    "Sync Kitsu lists, episode progress, and status securely.":
        "Synchronisiere Kitsu-Listen, Folgenfortschritt und Status sicher.",
    "Manage local viewers and their separate preferences.":
        "Lokale Zuschauer und ihre eigenen Einstellungen verwalten.",
    "Create, switch, or remove names stored locally on this device.":
        "Auf diesem Gerät gespeicherte Namen erstellen, wechseln oder entfernen.",
    "Names are stored only on this device and never include tracker credentials. The selected name is shared with Watch Party participants.":
        "Namen werden nur auf diesem Gerät gespeichert und enthalten keine Tracker-Zugangsdaten. Der gewählte Name wird mit Watch-Party-Teilnehmern geteilt.",
    "This removes only the local profile name. Shared history, settings, and connected trackers stay saved.":
        "Nur der lokale Profilname wird entfernt. Gemeinsamer Verlauf, Einstellungen und verbundene Tracker bleiben gespeichert.",
    "Choose when progress syncs and which episode alerts appear.":
        "Wähle, wann Fortschritt synchronisiert und welche Folgenhinweise angezeigt werden.",
    "Notify when a subtitled or simulcast episode reaches its normal airtime.":
        "Bei regulärer Ausstrahlung einer untertitelten oder Simulcast-Folge benachrichtigen.",
    "Notify only when a dubbed episode has a verified release schedule.":
        "Nur bei bestätigtem Veröffentlichungstermin einer synchronisierten Folge benachrichtigen.",
    "Control the optional Discord activity shown while you watch.":
        "Steuere die optionale Discord-Aktivität während der Wiedergabe.",
    "Remove this Discord connection from TetoTV on this device.":
        "Diese Discord-Verbindung auf diesem Gerät aus TetoTV entfernen.",
    "Manage this device, updates, diagnostics, privacy, storage, and legal information.":
        "Gerät, Updates, Diagnose, Datenschutz, Speicher und rechtliche Informationen verwalten.",
    "Setup, device compatibility, calibration, and diagnostics.":
        "Einrichtung, Gerätekompatibilität, Kalibrierung und Diagnose.",
    "Change setup method or reconnect your services.":
        "Einrichtungsmethode ändern oder Dienste erneut verbinden.",
    "Adjust display fit, input, and playback compatibility.":
        "Bildanpassung, Eingabe und Wiedergabekompatibilität einstellen.",
    "Review system health and export troubleshooting details.":
        "Systemzustand prüfen und Fehlerdiagnosedaten exportieren.",
    "Stable public releases download directly to this device.":
        "Stabile öffentliche Versionen werden direkt auf dieses Gerät heruntergeladen.",
    "Download signed updates automatically when a newer build is available.":
        "Signierte Updates automatisch herunterladen, sobald ein neuer Build verfügbar ist.",
    "Check this channel and open Android’s installer when the package is ready.":
        "Diesen Kanal prüfen und Androids Installer öffnen, sobald das Paket bereit ist.",
    "Fetch the signed release list for the selected update channel.":
        "Signierte Versionsliste für den ausgewählten Kanal abrufen.",
    "Signed releases download securely from the official TetoTV repository.":
        "Signierte Versionen werden sicher aus dem offiziellen TetoTV-Repository geladen.",
    "Remove temporary files or return TetoTV to first-time setup.":
        "Temporäre Dateien entfernen oder TetoTV auf Ersteinrichtung zurücksetzen.",
    "Remove temporary images, playback cache, and update leftovers. Accounts and settings stay saved.":
        "Temporäre Bilder, Wiedergabecache und Update-Reste entfernen. Konten und Einstellungen bleiben gespeichert.",
    "Erase accounts, preferences, sources, and history, then return to first-time setup.":
        "Konten, Einstellungen, Quellen und Verlauf löschen und zur Ersteinrichtung zurückkehren.",
    "Privacy, attribution, and open-source notices.":
        "Datenschutz, Urheberangaben und Open-Source-Hinweise.",
    "Review what TetoTV stores, processes, and shares.":
        "Prüfe, was TetoTV speichert, verarbeitet und teilt.",
    "Read attribution and open-source license notices.":
        "Urheberangaben und Open-Source-Lizenzhinweise lesen.",
    "Control optional privacy-safe reporting and Beta activity signals.":
        "Optionale datensparsame Berichte und Beta-Aktivitätssignale steuern.",
    "Review the optional privacy controls used by this build.":
        "Optionale Datenschutzeinstellungen dieses Builds prüfen.",
    "Send a redacted technical report after an unexpected crash.":
        "Nach unerwartetem Absturz einen bereinigten technischen Bericht senden.",
    "Include this device in the privacy-safe Beta activity count.":
        "Dieses Gerät in die datensparsame Beta-Aktivitätszählung einbeziehen.",
    "Validate and save this credential securely.":
        "Diese Zugangsdaten prüfen und sicher speichern.",
    "Open the secure device authorization flow.":
        "Sichere Geräteautorisierung öffnen.",
    "Open TorBox device authorization.": "TorBox-Geräteautorisierung öffnen.",
    "Remove the saved Real-Debrid connection.":
        "Gespeicherte Real-Debrid-Verbindung entfernen.",
    "Remove the saved TorBox connection.":
        "Gespeicherte TorBox-Verbindung entfernen.",
    "Choose your language": "Wähle deine Sprache",
    "This sets the app language and preferred audio and captions. You can change them separately later.":
        "Dadurch werden App-Sprache sowie bevorzugte Audio- und Untertitelsprache festgelegt. Du kannst sie später getrennt ändern.",
    "Also sets preferred audio and captions. You can change them separately in Playback.":
        "Legt auch bevorzugtes Audio und Untertitel fest. Unter Wiedergabe kannst du sie getrennt ändern.",
    "App language": "App-Sprache",
    "Appearance": "Darstellung",
    "Playback": "Wiedergabe",
    "Services": "Dienste",
    "Accounts": "Konten",
    "System": "System",
    "Settings": "Einstellungen",
    "Theme & display": "Design und Anzeige",
    "Theme Studio": "Designstudio",
    "Title language": "Titelsprache",
    "Show title style": "Titelstil",
    "Colors": "Farben",
    "Home screen": "Startbildschirm",
    "Featured hero": "Hauptbanner",
    "Poster metadata": "Posterinformationen",
    "Continue watching": "Weiterschauen",
    "Display options": "Anzeigeoptionen",
    "Interface scale": "Oberflächenskalierung",
    "Content density": "Inhaltsdichte",
    "Thumbnail size": "Vorschaubildgröße",
    "Layout style": "Layoutstil",
    "Default landing page": "Standardstartseite",
    "Card details": "Kartendetails",
    "Input & feedback": "Eingabe und Feedback",
    "Home shelves": "Startseitenbereiche",
    "Navigation": "Navigation",
    "Navigation size": "Navigationsgröße",
    "Menu order": "Menüreihenfolge",
    "Navigation sounds": "Navigationstöne",
    "Click sounds": "Klicktöne",
    "Closed captions": "Untertitel",
    "Player controls": "Player-Steuerung",
    "Debrid streaming": "Debrid-Streaming",
    "Sources & stream order": "Quellen und Streamreihenfolge",
    "Automatic source selection": "Automatische Quellenauswahl",
    "Libraries & features": "Bibliotheken und Funktionen",
    "Streaming privacy": "Streaming-Datenschutz",
    "Anime tracking": "Anime-Verfolgung",
    "Profiles": "Profile",
    "Progress & notifications": "Fortschritt und Benachrichtigungen",
    "Discord Rich Presence": "Discord-Aktivität",
    "Device & support": "Gerät und Support",
    "App updates": "App-Updates",
    "Community": "Community",
    "Storage & reset": "Speicher und Zurücksetzen",
    "About & legal": "Info und Rechtliches",
    "Privacy & diagnostics": "Datenschutz und Diagnose",
    "Search settings": "Einstellungen suchen",
    "No matching settings": "Keine passenden Einstellungen",
    "No matching settings found": "Keine passenden Einstellungen gefunden",
    "Expand all": "Alle aufklappen",
    "Collapse all": "Alle zuklappen",
    "Back": "Zurück",
    "Close": "Schließen",
    "Continue": "Weiter",
    "Cancel": "Abbrechen",
    "Delete": "Löschen",
    "Save": "Speichern",
    "Use": "Verwenden",
    "OK": "OK",
    "Try again": "Erneut versuchen",
    "Refresh": "Aktualisieren",
    "Reset defaults": "Standardwerte wiederherstellen",
    "On": "Ein",
    "Off": "Aus",
    "Automatic": "Automatisch",
    "Small": "Klein",
    "Medium": "Mittel",
    "Large": "Groß",
    "Compact": "Kompakt",
    "Standard": "Standard",
    "Comfortable": "Komfortabel",
    "Cinematic": "Kino",
    "Home": "Start",
    "Search": "Suche",
    "My List": "Meine Liste",
    "Discover": "Entdecken",
    "Calendar": "Kalender",
    "Watch Party": "Watch Party",
    "Downloads": "Downloads",
    "Play": "Abspielen",
    "Text title": "Texttitel",
    "Title logo": "Titellogo",
    "Top row": "Obere Leiste",
    "Profile menu": "Profilmenü",
    "Local profiles": "Lokale Profile",
    "New local profile": "Neues lokales Profil",
    "Display name": "Anzeigename",
    "No local profiles yet.": "Noch keine lokalen Profile.",
    "Select to enter a name": "Zum Eingeben eines Namens auswählen",
    "Select to open the TV keyboard": "Zum Öffnen der TV-Tastatur auswählen",
    "Default player": "Standardplayer",
    "Preferred audio": "Bevorzugtes Audio",
    "Preferred audio language": "Bevorzugte Audiosprache",
    "Preferred CC": "Bevorzugte Untertitel",
    "Preferred subtitle language": "Bevorzugte Untertitelsprache",
    "Follow Dub/Sub": "Dub/Sub folgen",
    "English for Dubbed, Japanese for Subtitled":
        "Englisch für Dub, Japanisch für Sub",
    "Media3 (Built in)": "Media3 (Integriert)",
    "MPV (Built in)": "MPV (Integriert)",
    "Media3 SurfaceView": "Media3 SurfaceView",
    "External player": "Externer Player",
    "Auto-skip intros": "Intros automatisch überspringen",
    "Auto-skip outros": "Outros automatisch überspringen",
    "Rewind": "Zurückspulen",
    "Fast-forward": "Vorspulen",
    "Text color": "Textfarbe",
    "Background": "Hintergrund",
    "Text size": "Textgröße",
    "Filler episode labels": "Filler-Folgen markieren",
    "Debrid provider": "Debrid-Anbieter",
    "Debrid streams": "Debrid-Streams",
    "Web streams": "Web-Streams",
    "Direct peer streaming": "Direktes Peer-Streaming",
    "Manage sources": "Quellen verwalten",
    "Debrid results": "Debrid-Ergebnisse",
    "Source priority": "Quellenpriorität",
    "Quality priority": "Qualitätspriorität",
    "Preferred Web quality": "Bevorzugte Webqualität",
    "Automatic selection": "Automatische Auswahl",
    "Strict audio": "Strenger Audiofilter",
    "Local, Jellyfin & Plex sources": "Lokale, Jellyfin- und Plex-Quellen",
    "Offline downloads": "Offline-Downloads",
    "Download manager": "Download-Manager",
    "Anime-list provider": "Anime-Listenanbieter",
    "When to update episode progress": "Folgenfortschritt aktualisieren",
    "Sub & simulcast alerts": "Sub- und Simulcast-Hinweise",
    "Verified dub alerts": "Bestätigte Dub-Hinweise",
    "Discord presence": "Discord-Aktivität",
    "Disconnect": "Trennen",
    "Connect Discord": "Discord verbinden",
    "Unlink Discord": "Discord-Verknüpfung lösen",
    "Connect by QR": "Per QR verbinden",
    "Personal API token": "Persönlicher API-Token",
    "Personal API key": "Persönlicher API-Schlüssel",
    "Personal Access Token": "Persönlicher Zugriffstoken",
    "Manual API token": "Manueller API-Token",
    "TorBox API token": "TorBox-API-Token",
    "Run setup again": "Einrichtung erneut starten",
    "Device calibration": "Gerätekalibrierung",
    "Diagnostics": "Diagnose",
    "Update channel": "Update-Kanal",
    "Release history": "Versionsverlauf",
    "Check now": "Jetzt prüfen",
    "Choose a compatible signed release": "Kompatible signierte Version wählen",
    "Privacy & data": "Datenschutz und Daten",
    "Third-party notices": "Drittanbieterhinweise",
    "Anonymous crash reports": "Anonyme Absturzberichte",
    "Anonymous live count": "Anonyme Aktivitätszählung",
    "Reset appearance and navigation":
        "Darstellung und Navigation zurücksetzen",
    "Reset appearance & navigation": "Darstellung und Navigation zurücksetzen",
    "Reset all TetoTV data?": "Alle TetoTV-Daten zurücksetzen?",
    "Erase everything": "Alles löschen",
    "Keep my data": "Meine Daten behalten",
    "Cancel reset": "Zurücksetzen abbrechen",
    "Final confirmation": "Letzte Bestätigung",
    "Support TetoTV": "TetoTV unterstützen",
    "Join the TetoTV Discord": "TetoTV-Discord beitreten",
    "Copy Discord invite": "Discord-Einladung kopieren",
    "Discord invite copied.": "Discord-Einladung kopiert.",
    "Copy Ko-fi link": "Ko-fi-Link kopieren",
    "Ko-fi donation link copied.": "Ko-fi-Spendenlink kopiert.",
  },
};
