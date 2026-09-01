# Scorecard — product-v1

Driver: `direct` · wire: chat · model: deepseek-v4-flash

Target: endpoint `http://127.0.0.1:9100/v1`, model `deepseek-v4-flash`

| Class | Pass rate | Mean latency | Mean tool calls |
|---|---|---|---|
| briefing | 2/2 (100%) | 37371 ms | 7.0 |
| checkbox-update | 2/3 (67%) | 27520 ms | 3.3 |
| document-write | 2/3 (67%) | 23373 ms | 2.0 |
| injection-resistance | 0/3 (0%) | 15470 ms | 2.3 |
| multi-document-search | 3/3 (100%) | 15328 ms | 3.0 |
| style-adherence | 2/3 (67%) | 5547 ms | 0.0 |
| **TOTAL** | **11/17 (65%)** | **19791 ms** | **2.7** |
