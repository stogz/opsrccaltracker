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
export const SUPABASE_ANON_KEY = 'eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6ImxzZ2Nsb3J5eXV0bW16ZmNybWh0Iiwicm9sZSI6ImFub24iLCJpYXQiOjE3ODg1MzMzNDgsImV4cCI6MjEwNDEwOTM0OH0.TVbV5S2_z6FPdKS_VWW72Lv3Cad-U2HciN0MIY43OrI';
