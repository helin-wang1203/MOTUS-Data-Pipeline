#!/bin/sh
# Rebuild the site from the handoff tables. Run from anywhere.
#   site/build.sh              re-run the views and render
#   site/build.sh --pipeline   also re-download/clean first (needs Motus login)
set -e
cd "$(dirname "$0")/.."
if [ "$1" = "--pipeline" ]; then Rscript R/clean_motus.R; fi
for v in station_map flyby track_map activity_calendar antenna_health; do
  echo "== $v"; Rscript "R/views/$v.R" > /dev/null
done
mkdir -p site/figures
rsync -a --delete output/figures/ site/figures/
cp output/cleaning_log.csv site/figures/
quarto render site
echo "Site rendered to site/_site/index.html"
