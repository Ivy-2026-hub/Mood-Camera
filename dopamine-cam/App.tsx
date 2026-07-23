import React, { useState, useRef, useCallback } from 'react';
import { Camera } from './components/Camera';
import { Polaroid } from './components/Polaroid';
import { PhotoData, AppState } from './types';
import { generatePhotoCaption } from './services/geminiService';
import { v4 as uuidv4 } from 'uuid';
import { Sparkles, RotateCcw, ImageDown } from 'lucide-react';

// Declare html2canvas from the global scope (loaded via CDN in index.html)
declare global {
  interface Window {
    html2canvas: any;
  }
}

const App: React.FC = () => {
  const videoRef = useRef<HTMLVideoElement>(null);
  const canvasRef = useRef<HTMLCanvasElement>(null);
  const galleryRef = useRef<HTMLDivElement>(null);
  
  const [photos, setPhotos] = useState<PhotoData[]>([]);
  const [appState, setAppState] = useState<AppState>(AppState.IDLE);
  const [selectedFilterId, setSelectedFilterId] = useState<string>('classic');
  const [isDownloadingWall, setIsDownloadingWall] = useState(false);
  
  // Temporary photo being "printed"
  const [printingPhoto, setPrintingPhoto] = useState<PhotoData | null>(null);

  // Initialize Camera
  React.useEffect(() => {
    const startCamera = async () => {
      try {
        const stream = await navigator.mediaDevices.getUserMedia({
          video: { width: { ideal: 1080 }, height: { ideal: 1080 }, facingMode: 'user' },
          audio: false,
        });
        if (videoRef.current) {
          videoRef.current.srcObject = stream;
        }
      } catch (err) {
        console.error("Error accessing camera:", err);
      }
    };
    startCamera();
  }, []);

  const handleTakePhoto = useCallback(async () => {
    if (appState !== AppState.IDLE || !videoRef.current || !canvasRef.current) return;

    // 1. Trigger Shutter / Flash State
    setAppState(AppState.SHOOTING);

    // 2. Capture after brief delay (sync with flash visual)
    setTimeout(() => {
      const video = videoRef.current;
      const canvas = canvasRef.current;
      const context = canvas?.getContext('2d');
      
      if (!video || !canvas || !context) return;

      // Set canvas to square
      const size = Math.min(video.videoWidth, video.videoHeight);
      canvas.width = size;
      canvas.height = size;

      // Crop to center square & flip horizontal
      const startX = (video.videoWidth - size) / 2;
      const startY = (video.videoHeight - size) / 2;
      
      context.translate(size, 0);
      context.scale(-1, 1);
      context.drawImage(video, startX, startY, size, size, 0, 0, size, size);

      const imageUrl = canvas.toDataURL('image/png');

      // 3. Create Photo Data
      const newPhoto: PhotoData = {
        id: uuidv4(),
        imageUrl,
        caption: '',
        filterId: selectedFilterId,
        timestamp: Date.now(),
        rotation: Math.random() * 6 - 3, // Sligth rotation for realism
        xOffset: 0,
        yOffset: 0,
        isLoadingCaption: true,
      };

      setPrintingPhoto(newPhoto);
      setAppState(AppState.PRINTING);

      // 4. Generate Caption
      generatePhotoCaption(imageUrl).then((caption) => {
        setPhotos((prev) => prev.map(p => p.id === newPhoto.id ? { ...p, caption, isLoadingCaption: false } : p));
      });

      // 5. Move to gallery after print animation
      setTimeout(() => {
        setPhotos((prev) => [newPhoto, ...prev]);
        setPrintingPhoto(null);
        setAppState(AppState.IDLE);
      }, 2200); // Match the animation duration roughly

    }, 100); 

  }, [appState, selectedFilterId]);

  const handleDownloadWall = async () => {
    if (!galleryRef.current || photos.length === 0 || isDownloadingWall) return;
    setIsDownloadingWall(true);

    try {
      // Wait for fonts to be ready
      await document.fonts.ready;

      // Capture the gallery div
      const canvas = await window.html2canvas(galleryRef.current, {
        scale: 2, // High resolution
        backgroundColor: '#fdf4f7', // Match the background
        useCORS: true,
        logging: false,
        // Ensure we capture the full scrollable area if needed, 
        // though current design is 45vh/auto.
      });

      const link = document.createElement('a');
      link.download = `my-dopamine-wall-${Date.now()}.png`;
      link.href = canvas.toDataURL('image/png');
      link.click();
    } catch (error) {
      console.error("Failed to download wall:", error);
    } finally {
      setIsDownloadingWall(false);
    }
  };

  return (
    <div className="min-h-screen w-full flex flex-col lg:flex-row overflow-hidden bg-[#fdf4f7] relative select-none">
      
      {/* Pattern Background */}
      <div className="absolute inset-0 opacity-40 pointer-events-none" style={{
        backgroundImage: `radial-gradient(#fb7185 1px, transparent 1px)`,
        backgroundSize: '24px 24px'
      }} />

      {/* Left Side: Studio / Camera */}
      <div className="flex-1 flex flex-col items-center justify-center p-4 relative h-[55vh] lg:h-auto z-20">
        
        {/* Logo */}
        <div className="absolute top-6 left-6 z-30 hidden lg:block">
           <div className="font-['Permanent_Marker'] text-4xl text-pink-500 -rotate-3 drop-shadow-sm flex items-center gap-2">
             <Sparkles size={32} className="text-yellow-400 fill-yellow-400" />
             Dopamine Cam
           </div>
           <p className="text-gray-400 font-['Fredoka'] text-sm ml-8">Point, shoot, and drag to organize.</p>
        </div>
        
        {/* Camera & Printing Mechanism Container */}
        <div className="relative flex items-center justify-center">
            
            {/* Printing Zone - Z-Index LOWER than camera so it slides out from behind */}
            <div className="absolute top-0 left-1/2 -translate-x-1/2 w-[240px] z-10 pointer-events-none">
               {printingPhoto && (
                 <Polaroid photo={printingPhoto} isPrinting={true} />
               )}
            </div>

            {/* The Camera itself */}
            <Camera 
              videoRef={videoRef}
              canvasRef={canvasRef}
              onTakePhoto={handleTakePhoto}
              appState={appState}
              selectedFilterId={selectedFilterId}
              onSelectFilter={setSelectedFilterId}
            />
        </div>
      </div>

      {/* Right Side: Gallery Wall (Draggable Zone) */}
      <div 
        ref={galleryRef}
        className="flex-1 h-[45vh] lg:h-auto bg-white/30 backdrop-blur-md border-t-4 lg:border-t-0 lg:border-l-4 border-white/60 relative shadow-inner overflow-hidden flex flex-col z-10 transition-all"
      >
        
        <div className="p-4 lg:p-6 border-b border-white/30 flex justify-between items-center bg-white/20 z-20 relative">
            <h2 className="font-['Fredoka'] font-semibold text-gray-500 uppercase tracking-widest text-sm flex items-center gap-2">
              <RotateCcw size={14} /> Photo Wall
            </h2>

            <div className="flex items-center gap-3">
              <span className="bg-white/80 px-3 py-1 rounded-full text-xs font-bold text-pink-500 shadow-sm">
                  {photos.length} Snaps
              </span>
              
              {photos.length > 0 && (
                <button 
                  onClick={handleDownloadWall}
                  disabled={isDownloadingWall}
                  className="bg-pink-500 hover:bg-pink-600 text-white p-2 rounded-full shadow-md transition-colors flex items-center gap-1 px-3"
                  title="Download Photo Wall"
                >
                   <ImageDown size={16} />
                   <span className="text-xs font-bold">{isDownloadingWall ? 'Saving...' : 'Save Wall'}</span>
                </button>
              )}
            </div>
        </div>

        <div className="flex-1 p-8 lg:p-12 relative w-full h-full overflow-visible">
            {photos.length === 0 && (
               <div className="absolute inset-0 flex flex-col items-center justify-center opacity-40 space-y-4 pointer-events-none">
                  <div className="w-32 h-40 border-4 border-dashed border-gray-400 rounded-lg flex items-center justify-center transform rotate-6">
                     <Sparkles size={40} className="text-gray-400" />
                  </div>
                  <p className="font-['Fredoka'] text-gray-500 text-lg">Your memories will appear here...</p>
               </div>
            )}
            
            {/* Flex container for initial layout, but items are draggable */}
            <div className="flex flex-wrap content-start justify-center gap-8 w-full h-full">
              {photos.map((photo) => (
                <div key={photo.id} className="relative">
                   <Polaroid photo={photo} dragConstraints={galleryRef} />
                </div>
              ))}
            </div>
        </div>
      </div>
    </div>
  );
};

export default App;