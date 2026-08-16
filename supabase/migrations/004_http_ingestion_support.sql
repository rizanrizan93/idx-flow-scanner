-- Enable server-side HTTP only for audited public-market ingestion helpers.
-- The application continues to preserve broker-evidence integrity; this extension
-- is used solely for public OHLCV retrieval and cannot populate broker evidence.
create extension if not exists http with schema extensions;
