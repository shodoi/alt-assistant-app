Requirements: AltText Generator Mobile
1. Project Overview
A mobile application that selects an image from the library and generates descriptive Alt text using the Gemini API. It supports conversational refinement and clipboard copying.

2. Technical Requirements
Platform: Flutter (Dart) or React Native (Expo)

AI Model: gemini-2.5-flash

Core Libraries:

Image Picker: For library access.

Generative AI SDK: To communicate with Gemini.

Secure Storage: To save the API Key locally.

3. Key Features & User Flow
Initial Setup:

User navigates to the Settings page to input and save their Gemini API Key.

Image Selection:

User taps a button to pick an image from the gallery.

Display the selected image preview.

Alt Text Generation:

Once an image is selected, the app automatically sends the image to Gemini with the prompt: "Generate a concise and accurate Alt text for this image for accessibility purposes."

Chat Refinement:

The generated text is displayed in a chat-like bubble.

User can type additional instructions (e.g., "Make it more professional" or "Mention the colors") to refine the text.

Copy to Clipboard:

A "Copy" button allows the user to copy the final text with one tap.

4. UI Structure
Home/Generator Page:

ImagePreviewWidget: Large area showing the selected image.

ChatHistoryWidget: List of AI responses and user instructions.

InputBar: Text field and "Send" button.

ActionButton: "Pick Image" and "Copy Text".

Settings Page:

TextField: For API Key entry.

SaveButton: To persist the key using secure storage.

5. Implementation Notes
Handle API errors gracefully (e.g., invalid key, no internet).

Ensure the image is resized/compressed if necessary before sending to the API.

Keep the UI clean and minimalist.