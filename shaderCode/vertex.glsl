varying vec2 vUv;

void main() {
    vUv = uv;
    // Proyección básica: Modelo -> Vista -> Proyección
    gl_Position = projectionMatrix * modelViewMatrix * vec4(position, 1.0);
}