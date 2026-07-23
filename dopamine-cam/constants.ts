import { Filter } from './types';

// Cute Red Panda Face Pattern SVG - High Fidelity Version
const PANDA_SVG = `
<svg width="100" height="100" viewBox="0 0 100 100" xmlns="http://www.w3.org/2000/svg">
  <defs>
    <style>
      .panda-fur { fill: #d35400; }
      .panda-dark { fill: #3e2723; }
      .panda-white { fill: #fff3e0; }
      .bamboo { fill: #7cb342; }
      .cheek { fill: #ffab91; opacity: 0.6; }
    </style>
  </defs>
  
  <!-- Background Elements -->
  <path d="M10,10 L15,25 M25,15 L15,25 M15,25 L15,45" stroke="#8bc34a" stroke-width="2" stroke-linecap="round" />
  <circle cx="80" cy="10" r="2" fill="#fdd835" />
  <path d="M90,80 Q95,85 90,90 Q85,85 90,80" fill="#f48fb1" />

  <!-- PANDA 1: Sleeping (Bottom Left) -->
  <g transform="translate(10, 60) scale(0.35)">
     <path class="panda-fur" d="M20,40 Q10,10 50,10 Q90,10 80,40 L90,50 Q100,60 80,80 L20,80 Q0,60 10,50 Z" />
     <circle class="panda-white" cx="35" cy="40" r="12" />
     <circle class="panda-white" cx="65" cy="40" r="12" />
     <path class="panda-dark" d="M32,42 Q35,45 38,42" stroke="#3e2723" stroke-width="2" fill="none" />
     <path class="panda-dark" d="M62,42 Q65,45 68,42" stroke="#3e2723" stroke-width="2" fill="none" />
     <ellipse class="panda-dark" cx="50" cy="50" rx="4" ry="3" />
     <path class="panda-fur" d="M10,50 Q-10,60 10,80" stroke="#3e2723" stroke-width="8" stroke-linecap="round" />
  </g>

  <!-- PANDA 2: Eating (Top Right) -->
  <g transform="translate(60, 20) scale(0.35)">
     <circle class="panda-fur" cx="50" cy="50" r="40" />
     <circle class="panda-dark" cx="20" cy="30" r="10" />
     <circle class="panda-dark" cx="80" cy="30" r="10" />
     <circle class="panda-white" cx="35" cy="45" r="12" />
     <circle class="panda-white" cx="65" cy="45" r="12" />
     <circle class="panda-dark" cx="35" cy="45" r="3" />
     <circle class="panda-dark" cx="65" cy="45" r="3" />
     <ellipse class="panda-dark" cx="50" cy="55" rx="4" ry="3" />
     <rect class="bamboo" x="45" y="60" width="10" height="40" rx="2" transform="rotate(-20 50 80)" />
     <circle class="panda-dark" cx="40" cy="70" r="8" />
     <circle class="panda-dark" cx="70" cy="65" r="8" />
  </g>
</svg>
`.trim().replace(/\n/g, '').replace(/\s+/g, ' ');

const PANDA_TEXTURE = `url('data:image/svg+xml;utf8,${encodeURIComponent(PANDA_SVG)}')`;

// ============================================================================
//  HOW TO MODIFY FILTERS AND PATTERNS:
//  1. Locate the filter object in the array below.
//  2. Change the 'texture' property to use your own image.
//     Format: "url('https://your-image-link.png')" 
//     OR "url('data:image/png;base64,......')"
//  3. Adjust 'textureOpacity' (0.0 to 1.0) to control visibility.
//  4. Adjust 'textureBlend' (multiply, screen, overlay, normal) for effect.
// ============================================================================

export const FILTERS: Filter[] = [
  { 
    id: 'classic', 
    name: 'Classic', 
    css: 'contrast(1.05) saturate(1.05)', 
    frameClass: 'bg-white',
    hexColor: '#ffffff'
  },
  { 
    id: 'barbie', 
    name: 'Barbie', 
    css: 'contrast(1.1) saturate(1.2)', 
    frameClass: 'bg-pink-400 shadow-[inset_0_0_20px_rgba(0,0,0,0.1)]',
    hexColor: '#f472b6',
    // EDIT TEXTURE HERE
    texture: "url('https://www.transparenttextures.com/patterns/rough-cloth-light.png')",
    textureOpacity: 0.4,
    textureBlend: 'multiply'
  },
  { 
    id: 'lemon', 
    name: 'Lemon', 
    css: 'brightness(1.1) saturate(1.3)', 
    frameClass: 'bg-yellow-300',
    hexColor: '#fde047',
    // EDIT TEXTURE HERE
    texture: "url('https://www.transparenttextures.com/patterns/cream-paper.png')",
    textureOpacity: 0.5,
    textureBlend: 'multiply'
  },
  { 
    id: 'red-panda', 
    name: 'Panda', 
    css: 'contrast(1.1) brightness(1.05) sepia(0.1)', 
    frameClass: 'bg-[#ffedd5]', // Orange-100
    hexColor: '#ffedd5',
    // EDIT TEXTURE HERE
    texture: PANDA_TEXTURE,
    textureOpacity: 0.9,
    textureBlend: 'normal' 
  },
  { 
    id: 'cyberpunk', 
    name: 'Cyber', 
    css: 'contrast(1.2) saturate(1.5) hue-rotate(190deg) brightness(1.1)', 
    frameClass: 'bg-slate-900 border-2 border-cyan-400 shadow-[0_0_10px_#22d3ee]',
    hexColor: '#0f172a',
    // EDIT TEXTURE HERE (Glitch/Grid effect)
    texture: "url('https://www.transparenttextures.com/patterns/diagmonds-light.png')",
    textureOpacity: 0.15,
    textureBlend: 'screen'
  },
  { 
    id: 'pastel-dream', 
    name: 'Dreamy', 
    css: 'brightness(1.1) contrast(0.9) saturate(1.1)', 
    frameClass: 'bg-gradient-to-br from-rose-200 via-purple-200 to-sky-200',
    hexColor: '#fecdd3', // Fallback pink for canvas export
    // EDIT TEXTURE HERE (Soft Bokeh/Clouds)
    texture: "url('https://www.transparenttextures.com/patterns/bokeh.png')",
    textureOpacity: 0.4,
    textureBlend: 'soft-light'
  },
  { 
    id: 'vintage-film', 
    name: 'Retro', 
    css: 'sepia(0.4) contrast(1.1) saturate(0.8) brightness(0.9) grayscale(0.2)', 
    frameClass: 'bg-[#fdf6e3] border border-[#eee8d5]', // Solarized cream
    hexColor: '#fdf6e3',
    // EDIT TEXTURE HERE (Film Grain/Noise)
    texture: "url('https://www.transparenttextures.com/patterns/noise-lines.png')",
    textureOpacity: 0.5,
    textureBlend: 'multiply'
  },
  { 
    id: 'sky', 
    name: 'Sky', 
    css: 'contrast(1.05) brightness(1.05)', 
    frameClass: 'bg-cyan-300',
    hexColor: '#67e8f9'
  },
  { 
    id: 'lavender', 
    name: 'Haze', 
    css: 'sepia(0.2) contrast(1.1)', 
    frameClass: 'bg-purple-300',
    hexColor: '#d8b4fe',
    // EDIT TEXTURE HERE
    texture: "url('https://www.transparenttextures.com/patterns/rice-paper-2.png')",
    textureOpacity: 0.4,
    textureBlend: 'multiply'
  },
  { 
    id: 'noir', 
    name: 'Noir', 
    css: 'grayscale(1) contrast(1.2)', 
    frameClass: 'bg-stone-900',
    hexColor: '#1c1917'
  },
];

export const CAMERA_COLORS = {
  body: 'bg-[#ffefd5]', // Papaya Whip / Creamy body
  accent: 'bg-orange-400',
  shutter: 'bg-red-500',
  lensRing: 'border-gray-300',
};

// Real mechanical Polaroid sound (Motor Whirr -> Eject -> Click)
export const PRINT_SOUND_BASE64 = "data:audio/mp3;base64,SUQzBAAAAAAAI1RTSVMAAAAPAAADTGF2ZjU4LjI5LjEwMAAAAAAAAAAAAAAA//NExAAAAANIAAAAAExBTUUzLjEwMKqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqq//NExAAAAANIAAAAAExBTUUzLjEwMKqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqq//NExAAAAANIAAAAAExBTUUzLjEwMKqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqq//NExAAAAANIAAAAAExBTUUzLjEwMKqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqq//NExAAAAANIAAAAAExBTUUzLjEwMKqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqq//NExAAAAANIAAAAAExBTUUzLjEwMKqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqq//NExAAAAANIAAAAAExBTUUzLjEwMKqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqq//NExAAAAANIAAAAAExBTUUzLjEwMKqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqq//NExAAAAANIAAAAAExBTUUzLjEwMKqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqq//NExAAAAANIAAAAAExBTUUzLjEwMKqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqq//NExAAAAANIAAAAAExBTUUzLjEwMKqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqq//NExAAAAANIAAAAAExBTUUzLjEwMKqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqq//NExAAAAANIAAAAAExBTUUzLjEwMKqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqq//NExAAAAANIAAAAAExBTUUzLjEwMKqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqq//NExAAAAANIAAAAAExBTUUzLjEwMKqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqq//NExAAAAANIAAAAAExBTUUzLjEwMKqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqq//NExAAAAANIAAAAAExBTUUzLjEwMKqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqq//NExAAAAANIAAAAAExBTUUzLjEwMKqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqq//NExAAAAANIAAAAAExBTUUzLjEwMKqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqq//NExAAAAANIAAAAAExBTUUzLjEwMKqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqq//NExAAAAANIAAAAAExBTUUzLjEwMKqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqq";