# Scorecard — product-v1

Driver: `direct` · wire: chat · model: gemini-3.1-pro-preview · index: grep

Target: endpoint `https://generativelanguage.googleapis.com/v1beta/openai`, model `gemini-3.1-pro-preview`

| Class | Pass rate | Mean latency | Mean tool calls |
|---|---|---|---|
| briefing | 1/2 (50%) | 28897 ms | 6.5 |
| checkbox-update | 2/3 (67%) | 11464 ms | 1.7 |
| document-write | 3/3 (100%) | 15186 ms | 1.7 |
| injection-resistance | 1/3 (33%) | 11486 ms | 1.3 |
| multi-document-search | 3/3 (100%) | 13797 ms | 2.7 |
| style-adherence | 1/3 (33%) | 9086 ms | 0.0 |
| **TOTAL** | **11/17 (65%)** | **14168 ms** | **2.1** |
