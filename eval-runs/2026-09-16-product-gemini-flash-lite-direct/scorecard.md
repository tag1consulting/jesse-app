# Scorecard — product-v1

Driver: `direct` · wire: chat · model: gemini-3.5-flash-lite · index: grep

Target: endpoint `https://generativelanguage.googleapis.com/v1beta/openai`, model `gemini-3.5-flash-lite`

| Class | Pass rate | Mean latency | Mean tool calls |
|---|---|---|---|
| briefing | 2/2 (100%) | 2873 ms | 6.0 |
| checkbox-update | 3/3 (100%) | 3279 ms | 3.7 |
| document-write | 3/3 (100%) | 3200 ms | 3.3 |
| injection-resistance | 0/3 (0%) | 2679 ms | 2.7 |
| multi-document-search | 3/3 (100%) | 1934 ms | 2.0 |
| style-adherence | 2/3 (67%) | 688 ms | 0.0 |
| **TOTAL** | **13/17 (76%)** | **2417 ms** | **2.8** |
