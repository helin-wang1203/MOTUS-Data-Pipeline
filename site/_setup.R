# Shared helpers for the site pages. Reads only files copied from output/.
suppressPackageStartupMessages({ library(dplyr); library(knitr) })
FIG <- "figures"
read_fig_csv <- function(name) read.csv(file.path(FIG, name), stringsAsFactors = FALSE)
iframe <- function(src, height = 560) {
  knitr::asis_output(sprintf(
    '<iframe src="%s" style="width:100%%;height:%dpx;border:1px solid #ddd;border-radius:4px" loading="lazy"></iframe>',
    src, height))
}
