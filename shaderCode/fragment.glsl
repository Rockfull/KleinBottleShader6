// 1. Uniforms: Datos que vienen de JavaScript
uniform float u_time;       // Tiempo para animaciones
uniform vec2 u_resolution;  // Resolución del canvas (ancho, alto)
uniform vec2 u_mouse;       // Posición del mouse
uniform sampler2D u_envMap; // Textura para los reflejos (Environment Map)

// 2. Constantes de Configuración del Raymarching
#define S 256   // [Pasos] Máximo número de pasos que el rayo avanza
#define P 0.001 // [Precisión] Distancia mínima para considerar que "tocamos" un objeto
#define R 2.    // [Sub-pasos] Factor para suavizar el avance (reduce artefactos)
#define D 15.   // [Distancia Máx] Si el rayo llega aquí, asumimos que es el cielo
#define M 0.    // [Muestras Extra] Para Anti-aliasing (0 para rendimiento)

#define PI 3.1415926

// 3. Estructuras de Datos
struct Ray { vec3 o; vec3 d; };     // Rayo: Origen (o) y Dirección (d)
struct Camera { vec3 p; vec3 t; };  // Cámara: Posición (p) y Objetivo (t)
struct Hit { vec3 p; float t; float d; }; // Golpe: Posición impacto, distancia total, distancia a superficie

// Variables globales para el estado del renderizado
Ray _ray;
Camera _cam;
float _d;           // Distancia actual
float _dsky;        // Distancia al "cielo" (esfera envolvente)
bool _ignoreBottle = false; // Bandera para ignorar la botella (usada en transparencia)

// 4. Funciones Auxiliares
// Rotación 2D estándar
mat2 rot(float a) {
    float c = cos(a), s = sin(a);
    return mat2(c, -s, s, c);
}

// Ruido aleatorio (Hash)
vec2 hash22(vec2 p) {
    return vec2(
        fract(sin(dot(p, vec2(50159.91193, 49681.51239))) * 73943.1699),
        fract(sin(dot(p, vec2(90821.40973, 2287.622010))) * 557.965570)
    );
}

// Función para mapear una dirección 3D a coordenadas UV 2D (Equirectangular)
// Necesario porque usamos un sampler2D en lugar de un samplerCube
vec2 envMapUV(vec3 dir) {
    vec2 uv = vec2(atan(dir.z, dir.x), asin(dir.y));
    uv *= vec2(0.1591, 0.3183); // Inversos de 2PI y PI
    uv += 0.5;
    return uv;
}

// 5. La Escena (SDF - Signed Distance Function)
// Aquí se define la forma matemática de la botella
float scene(vec3 p) {
    // Definimos el cielo como una esfera inversa gigante
    _dsky = abs(length(p) - D + 8.) - P;
    
    // Si estamos calculando transparencia trasera, ignoramos la botella
    if (_ignoreBottle) { return _d = _dsky; }
    
    // --- Construcción de la Botella ---
    float t = 0.02; // Grosor del vidrio
    float d = 1e10; // Distancia inicial muy grande
    
    // Pre-transformación: Centrar y rotar la botella
    p.y += .5;
    p.xy *= rot(PI / 2.); // Rotar 90 grados

    // Deformación para la curvatura de la botella
    vec3 q = p + vec3(1. - cos((1. - p.y) / 3. * PI), 0, 0);
    float y = pow(sin((1. - p.y) / 3. * PI / 2.), 2.);
     
    // Definición del cuerpo principal (cilindro hueco y sólido)
    float tube_hollow = max(max(abs(length(q.xz) - 0.5 + 0.25 * y) - t, q.y - 1.0), -q.y - 2.0);
    float tube_solid  = max(max(length(q.xz) - 0.5 + 0.25 * y, q.y - 1.0), -q.y - 2.0);
    
    // Apertura (boca de la botella) - Toroide cortado
    q = p - vec3(0, 1, 0);
    d = min(d, max(abs(length(vec2(length(q.xz) - 1.0, q.y)) - 0.5) - t, -q.y));
    
    // Cuerpo (unión suave de formas)
    q = p;
    d = min(d, max(max(max(abs(length(q.xz) - 1.5 + 1.25 * y), q.y - 1.0), -q.y - 2.0) - t, -tube_solid));
    
    // Añadir el tubo interior
    d = min(d, tube_hollow);
    
    // Asa de la botella (Handle) - Otro toroide desplazado
    q = p + vec3(1, 2, 0);
    d = min(d, max(abs(length(vec2(length(q.xy) - 1.0, q.z)) - 0.25) - t, q.y));
    
    // Combinar con el cielo
    d = min(d, _dsky);
    
    return _d = d;
}

// 6. Cálculo de Normales
// Calcula hacia dónde "mira" la superficie en el punto P
vec3 getNormal(vec3 p) {
    vec2 e = vec2(P, 0);
    return normalize(vec3(
        scene(p + e.xyy) - scene(p - e.xyy),
        scene(p + e.yxy) - scene(p - e.yxy),
        scene(p + e.yyx) - scene(p - e.yyx)
    ));
}

// 7. Raymarching (El Bucle Principal)
Hit march(Ray r) {
    float t = 0.0, d;
    for(int i = 0; i < S; i++) {
        d = scene(r.o + r.d * t); // Distancia a la superficie más cercana
        t += d / R;               // Avanzamos el rayo
        if (d < P || t > D) { break; } // ¿Tocamos algo o fuimos muy lejos?
    }
    return Hit(r.o + r.d * t, t, d);
}

// Configuración de la cámara
Ray lookAt(Camera cam, vec2 uv) {
    vec3 d = normalize(cam.t - cam.p); // Vector dirección hacia el objetivo
    vec3 r = normalize(cross(d, vec3(0, 1, 0))); // Vector derecha
    vec3 u = cross(r, d); // Vector arriba real
    return Ray(cam.p, normalize(r * uv.x + u * uv.y + d));
}

// 8. Sombreado y Material (Física del Vidrio)
vec3 getColor(Hit h) {
    // Si no golpeamos nada, negro
    if (_d > P) { return vec3(0); }
    // Si golpeamos el cielo, devolvemos la textura del entorno
    if (_d == _dsky) { return texture(u_envMap, envMapUV(getNormal(h.p))).rgb; }

    vec4 col = vec4(0);
    vec3 light = _cam.p; // La luz viene de la cámara (tipo flash)
    Hit _h = h; // Guardamos el primer impacto

    // --- Bucle de Rebotes de Luz (Reflexión/Refracción) ---
    // Simulamos múltiples rebotes dentro del vidrio
    for(int i = 0; i < 10; i++) {
        if (i == 2) { h = _h; }

        vec3 n = getNormal(h.p);

        // Iluminación Phong básica (Difusa + Especular)
        float diff = max(dot(normalize(light - h.p), n), 0.0);
        float spec = pow(max(dot(reflect(normalize(h.p - light), n), normalize(_cam.p - h.p)), 0.0), 100.);

        vec4 c = vec4(vec3(.8, .9, 1) * diff + spec, .15);
        
        // Si golpeamos el cielo en los primeros rebotes, tomamos su color
        if (i < 2 && _d == _dsky) { c = texture(u_envMap, envMapUV(n)); }

        // Efecto Fresnel (Bordes más reflectantes, centro más transparente)
        float r = 1.12;
        float f = r + (1. - r) * (1. - dot(normalize(h.p - _cam.p), n)) * 5.;
        c.rgb = mix(c.rgb, vec3(0), f);

        // Mezcla acumulativa de color (Alpha Blending manual)
        col.rgb = col.rgb * (1. - c.a) + c.rgb * c.a;
        col.w = clamp(col.w + c.a, 0., 1.);

        // Decidir el siguiente rayo: Refracción vs Reflexión
        if (i > 1) { 
             // Refracción (Luz atravesando el vidrio, índice 1.5)
             _ray.d = normalize(refract(h.p - _cam.p, n, 1.5)); 
        } else { 
             // Reflexión (Luz rebotando)
             _ray.d = normalize(reflect(h.p - _cam.p, n)); 
        }

        _ray.o = h.p + _ray.d * .1; // Mover origen para evitar auto-colisión
        h = march(_ray); // Siguiente paso del rayo
        
        if (h.d > P) { break; }
    }

    // 9. Transparencia Final (Ver a través de la botella)
    // Lanzamos un rayo final desde el primer impacto ignorando la botella
    _ray.d = normalize(_h.p - _cam.p);
    _ray.o = _h.p;
    
    _ignoreBottle = true; // Truco: desactivamos la botella en la función scene()
    h = march(_ray);
    _ignoreBottle = false;

    // Mezclamos el fondo visto a través de la botella con el color del vidrio acumulado
    vec3 bg = texture(u_envMap, envMapUV(getNormal(h.p))).rgb;
    return mix(bg, col.rgb, col.a);
}

void main() {
    // Normalización de coordenadas de pantalla (-1 a 1, ajustado por aspecto)
    vec2 uv = (2.0 * gl_FragCoord.xy - u_resolution.xy) / u_resolution.y;
    
    // Control del mouse
    vec2 uvm = (2.0 * u_mouse.xy - u_resolution.xy) / u_resolution.y;
    // Si el mouse no se usa, movimiento automático
    if (u_mouse.x < 10.0) { uvm = vec2(-u_time * .2, 0); }
    
    // Configuración de Cámara
    _cam = Camera(vec3(0, 0, 4), vec3(0, 0, 0)); // Cámara en Z=4 mirando al origen
    _cam.p.yz *= rot(-uvm.y * PI); // Rotación vertical
    _cam.p.xz *= rot(uvm.x * PI);  // Rotación horizontal
    
    // Lanzar rayo inicial
    _ray = lookAt(_cam, uv);
    vec3 col = getColor(march(_ray));

    // Anti-aliasing (Opcional, controlado por 'M')
    for (float i = 0.0; i < M; i++) {            
        _ray = lookAt(_cam, uv + hash22(uv * i) / u_resolution.xy * 2.);
        col += getColor(march(_ray));
    }

    // Viñeteado (Oscurecer bordes)
    float f = 1. - length((2.0 * gl_FragCoord.xy - u_resolution.xy) / u_resolution.xy) * 0.5;
    
    // Salida final de color
    gl_FragColor = vec4(col / (M + 1.) * f, 1.0);
}