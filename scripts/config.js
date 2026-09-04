// Supabase connection details for the browser client.
//
// The anon key is a PUBLIC key — it ships in every Supabase web app and is meant
// to be readable by anyone. It grants nothing on its own: row level security
// (supabase/migrations/0002_rls.sql) decides what any given caller may read or
// write. The service_role key is the secret one; it must never appear here.
//
// Find the anon key at:
//   Supabase dashboard -> Project Settings -> API Keys -> anon / public
export const SUPABASE_URL = 'https://lsgcloryyutmmzfcrmht.supabase.co';
export const SUPABASE_ANON_KEY = 'PASTE_YOUR_ANON_KEY_HERE';
