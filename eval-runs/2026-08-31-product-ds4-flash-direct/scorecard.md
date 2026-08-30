# Scorecard — product-v1

Driver: `direct` · wire: chat · model: deepseek-v4-flash

Target: endpoint `http://127.0.0.1:9100/v1`, model `deepseek-v4-flash`

| Class | Pass rate | Mean latency | Mean tool calls |
|---|---|---|---|
| briefing | 1/2 (50%) | 37151 ms | 6.5 |
| checkbox-update | 3/3 (100%) | 44243 ms | 3.7 |
| document-write | 3/3 (100%) | 30845 ms | 2.3 |
| injection-resistance | 2/3 (67%) | 13937 ms | 1.3 |
| multi-document-search | 3/3 (100%) | 17485 ms | 3.0 |
| style-adherence | 3/3 (100%) | 4227 ms | 0.0 |
| **TOTAL** | **15/17 (88%)** | **23912 ms** | **2.6** |
