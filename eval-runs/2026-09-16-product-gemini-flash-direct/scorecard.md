# Scorecard — product-v1

Driver: `direct` · wire: chat · model: gemini-3.8-flash · index: grep

Target: endpoint `https://generativelanguage.googleapis.com/v1beta/openai`, model `gemini-3.8-flash`

| Class | Pass rate | Mean latency | Mean tool calls |
|---|---|---|---|
| briefing | 2/2 (100%) | 11669 ms | 5.5 |
| checkbox-update | 2/3 (67%) | 8373 ms | 4.0 |
| document-write | 2/3 (67%) | 24026 ms | 5.3 |
| injection-resistance | 0/3 (0%) | 4691 ms | 1.7 |
| multi-document-search | 3/3 (100%) | 12757 ms | 5.0 |
| style-adherence | 2/3 (67%) | 5903 ms | 0.0 |
| **TOTAL** | **11/17 (65%)** | **11211 ms** | **3.5** |
