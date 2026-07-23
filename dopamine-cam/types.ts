export interface PhotoData {
  id: string;
  imageUrl: string;
  caption: string;
  filterId: string;
  timestamp: number;
  rotation: number;
  xOffset: number;
  yOffset: number;
  isLoadingCaption: boolean;
}

export interface Filter {
  id: string;
  name: string;
  css: string;       // CSS filter for the actual image
  frameClass: string; // Tailwind classes for the UI
  hexColor: string;   // Hex code for the canvas export
  texture?: string;   // Optional texture overlay
  textureOpacity?: number; // 0 to 1
  textureBlend?: string;   // CSS blend mode value
}

export enum AppState {
  IDLE = 'IDLE',
  COUNTDOWN = 'COUNTDOWN',
  SHOOTING = 'SHOOTING', // The split second of flash/shutter
  PRINTING = 'PRINTING', // The animation of paper coming out
}