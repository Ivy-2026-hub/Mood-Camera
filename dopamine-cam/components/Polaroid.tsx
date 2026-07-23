import React, { useRef } from 'react';
import { PhotoData } from '../types';
import { FILTERS } from '../constants';
import { motion } from 'framer-motion';
import { Download } from 'lucide-react';

interface PolaroidProps {
  photo: PhotoData;
  isPrinting?: boolean;
  dragConstraints?: React.RefObject<Element>;
}

export const Polaroid: React.FC<PolaroidProps> = ({ photo, isPrinting = false, dragConstraints }) => {
  const filterConfig = FILTERS.find(f => f.id === photo.filterId) || FILTERS[0];
  const { frameClass, css, hexColor, texture, textureOpacity = 0.3, textureBlend = 'multiply' } = filterConfig;
  const isDarkFrame = frameClass.includes('stone-900');

  // The printing animation state
  const printVariants = {
    initial: { y: 60, opacity: 1, scale: 0.95, zIndex: 5 },
    animate: { 
      y: -280, 
      opacity: 1, 
      scale: 1, 
      zIndex: 5,
      transition: { 
        duration: 2.0, 
        ease: [0.2, 0.8, 0.2, 1] // Custom bezier for mechanical ejection
      }
    },
  };

  // The gallery resting state
  const galleryStyle = {
    rotate: photo.rotation,
  };

  const handleDownload = async (e: React.MouseEvent) => {
    e.stopPropagation(); // Prevent drag start
    
    const canvas = document.createElement('canvas');
    const ctx = canvas.getContext('2d');
    if (!ctx) return;

    // 1. Wait for Font
    try {
      await document.fonts.load('10pt "Permanent Marker"');
    } catch (e) {
      console.warn("Font load check failed, proceeding anyway", e);
    }

    // 2. Configuration (High Res)
    const scale = 3; 
    const padding = 16 * scale; 
    const bottomChin = 100 * scale; // Generous space for caption
    const imageAspect = 4/5; // The vertical look of the polaroid
    
    // Base dimensions
    const canvasWidth = 260 * scale;
    const innerImageWidth = canvasWidth - (padding * 2);
    const innerImageHeight = innerImageWidth / imageAspect; 
    
    // Dynamic height based on content
    const canvasHeight = padding + innerImageHeight + bottomChin;

    canvas.width = canvasWidth;
    canvas.height = canvasHeight;

    // 3. Draw Frame Background
    ctx.fillStyle = hexColor;
    ctx.fillRect(0, 0, canvasWidth, canvasHeight);

    // 3b. Draw Texture if exists
    if (texture) {
      // Extract URL from "url('...')"
      const urlMatch = texture.match(/url\(['"]?(.*?)['"]?\)/);
      if (urlMatch && urlMatch[1]) {
        const texImg = new Image();
        texImg.crossOrigin = "anonymous";
        texImg.src = urlMatch[1];
        try {
          await new Promise((resolve) => {
             texImg.onload = resolve;
             texImg.onerror = resolve; // skip texture on error
          });
          
          ctx.save();
          // Map CSS blend modes to Canvas composite operations
          const gco = textureBlend === 'normal' ? 'source-over' : textureBlend;
          ctx.globalCompositeOperation = gco as GlobalCompositeOperation;
          ctx.globalAlpha = textureOpacity; 
          
          // Create pattern
          const pattern = ctx.createPattern(texImg, 'repeat');
          if (pattern) {
            ctx.fillStyle = pattern;
            ctx.fillRect(0, 0, canvasWidth, canvasHeight);
          }
          ctx.restore();
        } catch(e) {
           console.warn("Could not load texture for canvas");
        }
      }
    }

    // 4. Draw Image with "Object Cover" (Fixes stretching)
    const img = new Image();
    img.crossOrigin = "anonymous";
    img.src = photo.imageUrl;
    
    await new Promise((resolve) => {
      img.onload = resolve;
      img.onerror = resolve; 
    });

    // Draw black backing for photo area
    ctx.fillStyle = "#1a1a1a";
    ctx.fillRect(padding, padding, innerImageWidth, innerImageHeight);

    // -- Object Cover Logic --
    // Source dimensions
    const sw = img.naturalWidth;
    const sh = img.naturalHeight;
    // Target dimensions
    const dw = innerImageWidth;
    const dh = innerImageHeight;

    // Calculate scale to cover target completely
    const scaleFactor = Math.max(dw / sw, dh / sh);
    const scaledW = sw * scaleFactor;
    const scaledH = sh * scaleFactor;

    // Center the image
    const dx = padding + (dw - scaledW) / 2;
    const dy = padding + (dh - scaledH) / 2;

    ctx.save();
    // Create clipping region matching the inner photo box
    ctx.beginPath();
    ctx.rect(padding, padding, dw, dh);
    ctx.clip();

    // Apply filters
    ctx.filter = css; 
    ctx.drawImage(img, dx, dy, scaledW, scaledH);
    ctx.restore();
    ctx.filter = 'none';

    // 5. Gloss Overlay (Subtle)
    const gradient = ctx.createLinearGradient(0, canvasHeight, canvasWidth, 0);
    gradient.addColorStop(0, "rgba(255,255,255,0)");
    gradient.addColorStop(0.5, "rgba(255,255,255,0.05)");
    gradient.addColorStop(1, "rgba(255,255,255,0)");
    ctx.fillStyle = gradient;
    ctx.fillRect(padding, padding, innerImageWidth, innerImageHeight);

    // 6. Draw Caption
    ctx.font = `${22 * scale}px "Permanent Marker", cursive`;
    ctx.textAlign = "center";
    ctx.textBaseline = "middle";
    ctx.fillStyle = isDarkFrame ? "#f3f4f6" : "#1f2937";
    
    // Position text in the middle of the chin area
    const textX = canvasWidth / 2;
    const textY = padding + innerImageHeight + (bottomChin / 2) - (10 * scale); 
    
    const captionText = photo.caption || "";
    ctx.fillText(captionText, textX, textY);

    // 7. Draw Date
    ctx.font = `${10 * scale}px monospace`;
    ctx.textAlign = "right";
    ctx.fillStyle = isDarkFrame ? "rgba(255,255,255,0.4)" : "rgba(0,0,0,0.4)";
    const dateStr = new Date(photo.timestamp).toLocaleDateString(undefined, {month:'short', day:'numeric', year:'2-digit'});
    ctx.fillText(dateStr, canvasWidth - padding, canvasHeight - (padding/2));

    // 8. Download
    const link = document.createElement('a');
    link.download = `dopamine-snap-${photo.id.slice(0,6)}.png`;
    link.href = canvas.toDataURL('image/png');
    link.click();
  };

  return (
    <motion.div
      layoutId={isPrinting ? `print-${photo.id}` : undefined}
      drag={!isPrinting}
      dragConstraints={dragConstraints}
      dragElastic={0.1}
      dragMomentum={false}
      whileDrag={{ scale: 1.1, rotate: 0, zIndex: 100, cursor: 'grabbing' }}
      initial={isPrinting ? printVariants.initial : { opacity: 0, scale: 0.8, y: 50 }}
      animate={isPrinting ? printVariants.animate : { opacity: 1, scale: 1, y: 0, ...galleryStyle }}
      transition={isPrinting 
        ? printVariants.animate.transition 
        : { type: "spring", stiffness: 200, damping: 20 }
      }
      className={`
        relative group flex flex-col items-center p-3 pb-8 
        shadow-[0_4px_6px_-1px_rgba(0,0,0,0.1),0_2px_4px_-1px_rgba(0,0,0,0.06)]
        hover:shadow-2xl
        w-[220px] h-[260px] sm:w-[240px] sm:h-[290px] shrink-0
        transition-shadow duration-300
        overflow-hidden
        ${!isPrinting ? 'cursor-grab' : ''}
        ${frameClass} 
      `}
      style={{ transformOrigin: 'center center' }}
    >
      {/* Texture Overlay */}
      {texture && (
        <div 
          className="absolute inset-0 z-0 pointer-events-none"
          style={{ 
            backgroundImage: texture,
            opacity: textureOpacity,
            mixBlendMode: textureBlend as any
          }}
        />
      )}

      {/* The Photo Area */}
      <div className="relative w-full aspect-[4/5] bg-[#1a1a1a] overflow-hidden mb-3 shadow-inner z-10">
        <img 
          src={photo.imageUrl} 
          alt="Memory" 
          className="w-full h-full object-cover block select-none pointer-events-none"
          style={{ filter: css }}
        />
        
        {/* Developing Effect Overlay - Fades from black */}
        <motion.div 
          initial={{ opacity: 1 }}
          animate={{ opacity: 0 }}
          transition={{ duration: 5, ease: "easeIn" }}
          className="absolute inset-0 bg-[#0a0a0a] z-20 pointer-events-none"
        />

        {/* Glossy Overlay */}
        <div className="absolute inset-0 bg-gradient-to-tr from-white/5 via-white/20 to-transparent z-30 pointer-events-none opacity-50" />
      </div>

      {/* Caption Area */}
      <div className="w-full px-1 h-12 flex flex-col justify-between select-none pointer-events-none z-10">
        <div className={`
          font-['Permanent_Marker'] text-center leading-none text-lg
          ${photo.isLoadingCaption ? 'animate-pulse text-black/20' : 'text-gray-800'}
          ${isDarkFrame ? 'text-gray-200' : ''} 
        `}>
           {photo.isLoadingCaption ? "..." : photo.caption}
        </div>
        <div className={`text-[9px] font-mono opacity-40 text-right ${isDarkFrame ? 'text-white' : 'text-black'}`}>
            {new Date(photo.timestamp).toLocaleDateString(undefined, {month:'short', day:'numeric'})}
        </div>
      </div>

      {/* Download Button - Only visible on hover in gallery */}
      {!isPrinting && !photo.isLoadingCaption && (
        <button
          onClick={handleDownload}
          className="absolute -top-3 -right-3 bg-white text-gray-800 p-2 rounded-full shadow-lg opacity-0 group-hover:opacity-100 transition-opacity duration-200 hover:bg-gray-50 z-50 border border-gray-200 cursor-pointer"
          title="Download with Frame"
        >
          <Download size={16} />
        </button>
      )}
    </motion.div>
  );
};