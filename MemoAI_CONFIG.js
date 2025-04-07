// To enable AI Search, follow these steps:
// 1. Visit https://aistudio.google.com/prompts and generate an API key.
// 2. Paste your API key below. Do not share this key or this config file with others.
// 3. You can adjust the model by changing the value, e.g., "gemini-2.0-flash" or "gemini-2.0-flash-lite".
// 
// Important:
// - When you use AI Search, all your notes are converted into a large JSON and sent to Google's servers ofr AI processing.
// - The above referenced models (e.g., gemini-2.0-flash/-lite) support a context window of up to 1 million tokens.
//   This should handle a large number of notes, but it has not been tested with very large datasets.
// - This app stores your data locally in your browser using IndexedDB.
//   Your notes are not stored or sent anywhere unless you use AI Search.

// You can change the DB_NAME below if you want to switch to another database, your current one will persist so just change the name back.

const CONFIG = {
    GEMINI_API_KEY: 'AIzaSyAbKHJ9ISppPuZLP7UTu16OwLoNaiucS0U', // <-- Change your key here
    GEMINI_MODEL: 'gemini-2.0-flash-lite',
	DB_NAME: 'MarkdownCardsDB-0003'
};