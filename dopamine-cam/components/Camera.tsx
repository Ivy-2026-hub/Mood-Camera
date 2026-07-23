import React, { useState, useEffect, useRef } from 'react';
import { FILTERS, CAMERA_COLORS } from '../constants';
import { AppState } from '../types';
import { Zap, ZapOff, Timer, TimerReset } from 'lucide-react';

interface CameraProps {
  videoRef: React.RefObject<HTMLVideoElement>;
  canvasRef: React.RefObject<HTMLCanvasElement>;
  onTakePhoto: () => void;
  appState: AppState;
  selectedFilterId: string;
  onSelectFilter: (id: string) => void;
}

export const Camera: React.FC<CameraProps> = ({
  videoRef,
  canvasRef,
  onTakePhoto,
  appState,
  selectedFilterId,
  onSelectFilter
}) => {
  const [flashEnabled, setFlashEnabled] = useState(true);
  const [timerDuration, setTimerDuration] = useState<0 | 3 | 10>(0);
  const [countdown, setCountdown] = useState<number | null>(null);
  
  // Audio Context Ref to reuse context
  const audioCtxRef = useRef<AudioContext | null>(null);

  const getAudioContext = () => {
    if (!audioCtxRef.current) {
      audioCtxRef.current = new (window.AudioContext || (window as any).webkitAudioContext)();
    }
    if (audioCtxRef.current.state === 'suspended') {
      audioCtxRef.current.resume();
    }
    return audioCtxRef.current;
  };

  const playTickSound = (isLast: boolean) => {
    try {
      const ctx = getAudioContext();
      const t = ctx.currentTime;
      const osc = ctx.createOscillator();
      const gain = ctx.createGain();

      osc.type = 'sine';
      // Higher pitch for the final count
      osc.frequency.setValueAtTime(isLast ? 1200 : 800, t); 
      
      gain.gain.setValueAtTime(0.1, t);
      gain.gain.exponentialRampToValueAtTime(0.01, t + 0.1);

      osc.connect(gain);
      gain.connect(ctx.destination);

      osc.start(t);
      osc.stop(t + 0.1);
    } catch (e) {
      console.error("Audio tick failed", e);
    }
  };
  
  const playPrintSound = () => {
    try {
      const ctx = getAudioContext();
      const t = ctx.currentTime;

      // DURATION OF PRINT
      const duration = 1.8; 

      // 1. MECHANICAL MOTOR HUM (Sawtooth wave)
      const motorOsc = ctx.createOscillator();
      motorOsc.type = 'sawtooth';
      // Start low pitch, ramp up slightly, then hold
      motorOsc.frequency.setValueAtTime(80, t);
      motorOsc.frequency.linearRampToValueAtTime(110, t + 0.2);
      motorOsc.frequency.setValueAtTime(110, t + duration - 0.2);
      motorOsc.frequency.linearRampToValueAtTime(60, t + duration);

      const motorGain = ctx.createGain();
      motorGain.gain.setValueAtTime(0, t);
      motorGain.gain.linearRampToValueAtTime(0.15, t + 0.1);
      motorGain.gain.setValueAtTime(0.15, t + duration - 0.1);
      motorGain.gain.linearRampToValueAtTime(0, t + duration);

      // Lowpass filter to muffle the harsh sawtooth
      const motorFilter = ctx.createBiquadFilter();
      motorFilter.type = 'lowpass';
      motorFilter.frequency.value = 400;

      motorOsc.connect(motorFilter);
      motorFilter.connect(motorGain);
      motorGain.connect(ctx.destination);

      motorOsc.start(t);
      motorOsc.stop(t + duration);

      // 2. MECHANICAL GEAR NOISE (White Noise)
      const bufferSize = ctx.sampleRate * duration;
      const buffer = ctx.createBuffer(1, bufferSize, ctx.sampleRate);
      const data = buffer.getChannelData(0);
      for (let i = 0; i < bufferSize; i++) {
        data[i] = Math.random() * 2 - 1;
      }
      const noise = ctx.createBufferSource();
      noise.buffer = buffer;

      const noiseFilter = ctx.createBiquadFilter();
      noiseFilter.type = 'bandpass';
      noiseFilter.frequency.value = 1000;
      noiseFilter.Q.value = 1;

      const noiseGain = ctx.createGain();
      noiseGain.gain.setValueAtTime(0, t);
      noiseGain.gain.linearRampToValueAtTime(0.05, t + 0.1);
      noiseGain.gain.setValueAtTime(0.05, t + duration - 0.1);
      noiseGain.gain.linearRampToValueAtTime(0, t + duration);

      noise.connect(noiseFilter);
      noiseFilter.connect(noiseGain);
      noiseGain.connect(ctx.destination);
      noise.start(t);

      // 3. INITIAL SHUTTER CLICK (Short thud)
      const clickOsc = ctx.createOscillator();
      clickOsc.type = 'square';
      clickOsc.frequency.setValueAtTime(150, t);
      clickOsc.frequency.exponentialRampToValueAtTime(0.01, t + 0.1);
      
      const clickGain = ctx.createGain();
      clickGain.gain.setValueAtTime(0.3, t);
      clickGain.gain.exponentialRampToValueAtTime(0.01, t + 0.1);

      clickOsc.connect(clickGain);
      clickGain.connect(ctx.destination);
      clickOsc.start(t);
      clickOsc.stop(t + 0.1);

    } catch (e) {
      console.error("Audio synth failed", e);
    }
  };

  const handleShutterClick = () => {
    if (appState !== AppState.IDLE || countdown !== null) return;

    if (timerDuration === 0) {
      // Instant photo
      playPrintSound();
      onTakePhoto();
    } else {
      // Start Countdown
      startCountdown(timerDuration);
    }
  };

  const startCountdown = (seconds: number) => {
    setCountdown(seconds);
    playTickSound(false);
    
    let remaining = seconds;
    const interval = setInterval(() => {
      remaining -= 1;
      
      if (remaining > 0) {
        setCountdown(remaining);
        playTickSound(false);
      } else {
        // Time up!
        clearInterval(interval);
        setCountdown(null);
        playTickSound(true); // Final beep
        playPrintSound();
        onTakePhoto();
      }
    }, 1000);
  };

  const toggleTimer = () => {
    if (timerDuration === 0) setTimerDuration(3);
    else if (timerDuration === 3) setTimerDuration(10);
    else setTimerDuration(0);
  };

  const activeFilter = FILTERS.find(f => f.id === selectedFilterId);
  const isShooting = appState === AppState.SHOOTING;

  return (
    <div className="relative flex flex-col items-center justify-center w-full max-w-md mx-auto z-20">
      
      {/* 
          GLOBAL FLASH OVERLAY 
          Moved outside the transformed camera container to ensure it covers the FULL screen without being clipped.
      */}
      <div 
        className="fixed inset-0 bg-white pointer-events-none z-[9999]"
        style={{
          opacity: isShooting && flashEnabled ? 1 : 0,
          // Instant ON (0s), slow fade OFF (800ms) to simulate eye recovery
          transition: isShooting ? 'opacity 0s' : 'opacity 800ms ease-out'
        }}
      />

      {/* Camera Body Container */}
      <div className={`
        relative w-[340px] h-[340px] sm:w-[420px] sm:h-[420px] 
        ${CAMERA_COLORS.body} 
        rounded-[3rem] shadow-[0_20px_50px_rgba(0,0,0,0.3),inset_0_-10px_20px_rgba(0,0,0,0.1)]
        border-b-[12px] border-r-[12px] border-black/5
        flex items-center justify-center
        transition-transform duration-100
        ${isShooting ? 'scale-[0.98] translate-y-1' : ''}
      `}>
        
        {/* Texture Overlay */}
        <div className="absolute inset-0 rounded-[3rem] opacity-30 bg-[url('https://www.transparenttextures.com/patterns/leather.png')] pointer-events-none mix-blend-multiply" />

        {/* The Slot (Top) - Needs to look like an opening */}
        <div className="absolute -top-3 left-1/2 -translate-x-1/2 w-2/3 h-6 bg-black/80 rounded-full z-0 shadow-inner border-b border-white/10" />

        {/* Viewfinder / Lens Area */}
        <div className="relative w-[240px] h-[240px] sm:w-[280px] sm:h-[280px] bg-[#e8e8e8] rounded-full shadow-[inset_0_4px_10px_rgba(0,0,0,0.2)] flex items-center justify-center border border-white">
          
          {/* Inner Lens Ring */}
          <div className="relative w-[200px] h-[200px] sm:w-[240px] sm:h-[240px] bg-black rounded-full border-[12px] border-gray-300 shadow-2xl overflow-hidden flex items-center justify-center">
            
            {/* The Actual Video Feed */}
            <video
              ref={videoRef}
              autoPlay
              playsInline
              muted
              className={`absolute inset-0 w-full h-full object-cover transition-all duration-300 scale-x-[-1]`}
              style={{ filter: activeFilter?.css }}
            />
            <canvas ref={canvasRef} className="hidden" />

            {/* COUNTDOWN OVERLAY */}
            {countdown !== null && (
              <div key={countdown} className="relative z-40 text-white font-['Fredoka'] text-9xl font-bold drop-shadow-lg animate-ping-once">
                {countdown}
              </div>
            )}

            {/* Lens Reflection / Glass Effect */}
            <div className="absolute inset-0 bg-gradient-to-tr from-purple-500/10 via-transparent to-cyan-500/10 pointer-events-none rounded-full" />
            <div className="absolute top-4 right-8 w-8 h-4 bg-white/40 blur-md rounded-full -rotate-45" />
            <div className="absolute bottom-8 left-8 w-4 h-2 bg-white/20 blur-sm rounded-full -rotate-45" />
          </div>
        </div>

        {/* Flash Bulb */}
        <div className="absolute top-8 right-8 w-14 h-10 bg-white border-2 border-gray-200 rounded-xl shadow-sm flex items-center justify-center overflow-hidden">
            <div className="absolute inset-0 bg-[radial-gradient(circle_at_center,_var(--tw-gradient-stops))] from-gray-100 to-gray-300" />
            <button 
              onClick={() => setFlashEnabled(!flashEnabled)}
              className={`relative z-10 p-1 rounded-full transition-colors ${flashEnabled ? 'text-orange-500' : 'text-gray-400'}`}
              title="Flash Toggle"
            >
               {flashEnabled ? <Zap size={18} fill="currentColor" /> : <ZapOff size={18} />}
            </button>
        </div>

        {/* Timer Button */}
        <div className="absolute top-8 left-8 w-14 h-10 bg-white border-2 border-gray-200 rounded-xl shadow-sm flex items-center justify-center overflow-hidden">
             <div className="absolute inset-0 bg-[radial-gradient(circle_at_center,_var(--tw-gradient-stops))] from-gray-100 to-gray-300" />
             <button 
              onClick={toggleTimer}
              className={`relative z-10 p-1 rounded-full transition-colors flex flex-col items-center justify-center ${timerDuration > 0 ? 'text-blue-500' : 'text-gray-400'}`}
              title="Self Timer"
            >
               {timerDuration === 0 ? (
                 <TimerReset size={18} />
               ) : (
                 <div className="relative">
                   <Timer size={18} />
                   <span className="absolute -bottom-2 -right-2 text-[9px] font-black bg-white rounded-full px-1 border border-gray-200">
                     {timerDuration}s
                   </span>
                 </div>
               )}
            </button>
        </div>

        {/* Viewfinder Window (Optical) - Moved down slightly to accommodate symmetry if needed, but looks ok */}
        <div className="hidden sm:block absolute bottom-8 left-10 w-12 h-12 bg-gray-800 rounded-lg border-4 border-gray-300 shadow-inner overflow-hidden">
           <div className="w-full h-full bg-gradient-to-br from-blue-900 to-black opacity-80"></div>
           <div className="absolute top-1 left-1 w-3 h-3 bg-white/20 rounded-full blur-[1px]"></div>
        </div>

        {/* Shutter Button */}
        <button
          onClick={handleShutterClick}
          disabled={appState !== AppState.IDLE || countdown !== null}
          className={`
            absolute bottom-8 right-6 sm:bottom-10 sm:right-8 
            w-16 h-16 sm:w-20 sm:h-20 rounded-full 
            ${CAMERA_COLORS.shutter} 
            border-4 border-white/80 shadow-[0_4px_0_rgb(180,0,0)]
            active:shadow-none active:translate-y-[4px] active:border-gray-300
            transition-all duration-100
            flex items-center justify-center group cursor-pointer z-30
            ${countdown !== null ? 'opacity-80 cursor-wait' : ''}
          `}
        >
           <div className="w-full h-full rounded-full bg-gradient-to-br from-white/20 to-transparent" />
        </button>

        {/* Brand Label */}
        <div className="absolute bottom-8 left-8 sm:left-24 transform -rotate-6">
           <div className="bg-yellow-400 text-purple-900 px-3 py-1 rounded border-2 border-white shadow-md font-black font-mono text-xs tracking-widest uppercase">
              G-C AM
           </div>
        </div>
      </div>

      {/* Visual Film Strip Selector */}
      <div className="mt-8 w-full max-w-[480px]">
         <div className="text-center mb-2 font-['Fredoka'] text-gray-400 text-sm uppercase tracking-wider">Pick your film</div>
         <div className="flex gap-4 overflow-x-auto pb-6 pt-2 px-4 no-scrollbar snap-x justify-start sm:justify-center mask-linear-fade">
            {FILTERS.map(filter => (
              <button
                key={filter.id}
                onClick={() => onSelectFilter(filter.id)}
                className={`
                   relative shrink-0 snap-center group
                   flex flex-col items-center
                   transition-all duration-300
                   ${selectedFilterId === filter.id ? 'scale-110 -translate-y-2' : 'opacity-60 hover:opacity-100 hover:scale-105'}
                `}
              >
                 {/* Mini Polaroid Preview */}
                 <div 
                    className={`
                      w-12 h-14 p-1 shadow-md flex flex-col items-center
                      ${filter.frameClass} 
                      ${selectedFilterId === filter.id ? 'shadow-xl ring-2 ring-offset-2 ring-blue-400' : ''}
                    `}
                    style={{
                        // SHOW TEXTURE IN PREVIEW
                        backgroundImage: filter.texture,
                        backgroundSize: '200%', // Zoom in a bit for the tiny icon
                        backgroundPosition: 'center',
                        mixBlendMode: filter.textureBlend === 'multiply' ? undefined : 'normal'
                    }}
                 >
                    {/* Darken overlay if it's a multiply blend to simulate the effect on color */}
                     {filter.textureBlend === 'multiply' && (
                         <div className="absolute inset-0 bg-black/10 pointer-events-none" />
                     )}

                    <div className="w-full h-10 bg-gray-900 overflow-hidden relative z-10">
                        {/* Simulated gradient content */}
                        <div className="w-full h-full bg-gradient-to-br from-gray-700 to-black opacity-50" />
                    </div>
                 </div>
                 
                 <span className={`mt-2 text-[10px] font-bold uppercase tracking-wide ${selectedFilterId === filter.id ? 'text-gray-800' : 'text-gray-400'}`}>
                   {filter.name}
                 </span>
              </button>
            ))}
         </div>
      </div>

      <style jsx>{`
        @keyframes ping-once {
          0% { transform: scale(0.5); opacity: 0; }
          50% { transform: scale(1.2); opacity: 1; }
          100% { transform: scale(1); opacity: 1; }
        }
        .animate-ping-once {
          animation: ping-once 0.4s cubic-bezier(0, 0, 0.2, 1);
        }
      `}</style>
    </div>
  );
};