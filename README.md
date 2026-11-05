# MOTUS-Data-Pipeline

Data pipeline for the Dartmouth Organic Farm Motus wildlife-tracking station
(ENGS 89/190 capstone, 2026–27). Turns Motus detections into clean handoff
tables and visualizations.

- `R/clean_motus.R` — download, clean, and write the handoff tables to `output/`
- `tests/test_cleaning.R` — synthetic tests, no network needed
- `R/views/` — one script per visualization (in progress)

Setup, rules, and the full plan are in [CLAUDE.md](CLAUDE.md).

```sh
Rscript R/clean_motus.R
Rscript tests/test_cleaning.R
```
