/// Terms of use and research consent for the Nisaab AI pilot study.
///
/// [kTermsVersion] must equal `terms_version` in backend/config.py. Change both together whenever
/// the text changes: the server then asks every user to accept the new version.
library;

const String kTermsVersion = '2026.10';

const String kConsentSummary =
    'I agree to the terms of use and to my anonymised entries being used in the Nisaab AI research study.';

/// (heading, body) sections shown in the full terms sheet.
const List<(String, String)> kTermsSections = [
  (
    'About this study',
    'Nisaab AI is a final-year research project at KSBL (Department of Business Analytics) by '
        'Muhammad Usman Shahid and Talha Ather. The app is used to study automatic expense '
        'classification, spending forecasts and AI financial guidance for young people in Pakistan.',
  ),
  (
    'What is collected',
    'The transactions you enter (the text or voice transcript, amount, category, merchant and date), '
        'any corrections you make, your budgets and savings goals, the questions you ask the assistant, '
        'and when you use the app. Your name, email and phone number are stored to run your account.',
  ),
  (
    'How it is used',
    'To measure how accurately the app classifies and forecasts spending and how useful its advice is. '
        'Before analysis, your account is replaced by a random code, and names, phone numbers, CNIC, '
        'account and card numbers are removed from the text. Results are reported only in aggregate. '
        'Your data is never sold or shared with anyone outside the project team.',
  ),
  (
    'AI assistant',
    'If the AI assistant is switched on, your question and a summary of your finances (with your first '
        'name only, no email or phone) are sent to Anthropic\'s Claude model to write the reply.',
  ),
  (
    'Your choices',
    'Taking part is voluntary. You can stop at any time: Profile → Delete account permanently erases your '
        'account and all of your data, and nothing about you is used after that. You must be 18 or older.',
  ),
  (
    'Not financial advice',
    'Nisaab gives general information based on what you enter. It is not professional financial advice.',
  ),
];
