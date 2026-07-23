import { GoogleGenAI, Type } from "@google/genai";

// Helper to clean base64 string
const cleanBase64 = (dataUrl: string) => {
  return dataUrl.replace(/^data:image\/(png|jpg|jpeg);base64,/, "");
};

export const generatePhotoCaption = async (base64Image: string): Promise<string> => {
  if (!process.env.API_KEY) {
    console.warn("API_KEY not found in environment.");
    return "moment captured 📸";
  }

  try {
    const ai = new GoogleGenAI({ apiKey: process.env.API_KEY });
    
    const response = await ai.models.generateContent({
      model: 'gemini-2.5-flash',
      contents: {
        parts: [
          {
            inlineData: {
              mimeType: 'image/png',
              data: cleanBase64(base64Image)
            }
          },
          {
            text: `Analyze this photo and generate a short, observant, and witty caption.
            
            Rules:
            1. Maximum 7 words.
            2. Describe the specific ACTION, OBJECT, or MOOD visible in the image (e.g., "messy hair," "coffee break," "sunset glow"). 
            3. Avoid generic slang (like "vibes" or "slay") unless it fits perfectly. Be specific.
            4. Can be slightly abstract or poetic.
            5. Use lowercase text only (for the aesthetic).
            6. Include exactly one relevant emoji at the end.
            
            Examples of desired output:
            - 'sunlight hitting the messy desk ☀️'
            - 'half awake but trying ☕'
            - 'blue shirt kind of day 👕'
            - 'accidentally cinematic 🎬'
            - 'caught in 4k staring at nothing 👀'
            - 'proof that i went outside 🌲'
            
            Return ONLY the caption text.`
          }
        ]
      },
      config: {
        systemInstruction: "You are an observant, creative photographer who notices small details and specific moods.",
        thinkingConfig: { thinkingBudget: 0 }, 
        temperature: 1.2, 
      }
    });

    return response.text?.trim() || "moment captured 📸";
  } catch (error) {
    console.error("Error generating caption:", error);
    return "memory unlocked 📸";
  }
};