#include <flutter/runtime_effect.glsl>

uniform vec2 uSize;
uniform float invertStrength;
uniform sampler2D image;

// Convert color from RGB color space to HSL color space
// Source: https://stackoverflow.com/a/9493060/1310978

vec3 rgb_to_hsl(vec3 color) {
    vec3 hsl;
    float fmin = min(min(color.r, color.g), color.b);
    float fmax = max(max(color.r, color.g), color.b);
    float delta = fmax - fmin;
    hsl.z = (fmax + fmin) / 2.0; // Lightness
    if (delta == 0.0) {
        hsl.x = 0.0; // Hue
        hsl.y = 0.0; //Saturation
    } else {
        if (hsl.z < 0.5) {
            hsl.y = delta / (fmax + fmin);
        } else {
            hsl.y = delta / (2.0 - fmax - fmin);
        }
        float delta_r = (((fmax - color.r) / 6.0) + (delta / 2.0)) / delta;
        float delta_g = (((fmax - color.g) / 6.0) + (delta / 2.0)) / delta;
        float delta_b = (((fmax - color.b) / 6.0) + (delta / 2.0)) / delta;
        if (color.r == fmax) {
            hsl.x = delta_b - delta_g;
        } else if (color.g == fmax) {
            hsl.x = (1.0 / 3.0) + delta_r - delta_b;
        } else if (color.b == fmax) {
            hsl.x = (2.0 / 3.0) + delta_g - delta_r;
        }
        if (hsl.x < 0.0) {
            hsl.x += 1.0;
        }
        if (hsl.x > 1.0) {
            hsl.x -= 1.0;
        }
    }
    return hsl;
}

// Helper function for HSL to RGB conversion.
float hue_to_rgb(float f1, float f2, float hue) {
    if (hue < 0.0) {
        hue += 1.0;
    }
    if (hue > 1.0) {
        hue -= 1.0;
    }
    if ((6.0 * hue) < 1.0) {
        return f1 + (f2 - f1) * 6.0 * hue;
    }
    if ((2.0 * hue) < 1.0) {
        return f2;
    }
    if ((3.0 * hue) < 2.0) {
        return f1 + (f2 - f1) * ((2.0 / 3.0) - hue) * 6.0;
    }
    return f1;
}

// Convert color from HSL color space to RGB color space
vec3 hsl_to_rgb(vec3 hsl) {
    if (hsl.y == 0.0) {
        return vec3(hsl.z);
    }
    float f2;
    if (hsl.z < 0.5) {
        f2 = hsl.z * (1.0 + hsl.y);
    } else {
        f2 = (hsl.z + hsl.y) - (hsl.y * hsl.z);
    }
    float f1 = 2.0 * hsl.z - f2;
    return vec3(
        hue_to_rgb(f1, f2, hsl.x + (1.0/3.0)),
        hue_to_rgb(f1, f2, hsl.x),
        hue_to_rgb(f1, f2, hsl.x - (1.0/3.0))
    );
}

// Main shader function
out vec4 fragColor;

void main() {
    vec2 uv = FlutterFragCoord().xy / uSize;

    // Get the original color of the pixel from the image
    vec4 original_color = texture(image, uv);

    // Convert color to HSL
    vec3 hsl_color = rgb_to_hsl(original_color.rgb);

    // Invert the Lightness component
    hsl_color.z = invertStrength - hsl_color.z;

    // Convert the modified HSL color back to RGB
    vec3 inverted_rgb = hsl_to_rgb(hsl_color);

    // Output the final color, preserving the original transparency
    fragColor = vec4(inverted_rgb, original_color.a);
}
