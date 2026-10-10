#!/usr/bin/env Rscript

# Workflow 09 manuscript comparison figure: systematic-review topic coverage.
#
# These counts are the fixed secondary-research data supplied in the manuscript
# draft (37 systematic reviews). This figure is deliberately rendered without
# the former internal title/subtitle or bottom axis/caption text so that the
# manuscript caption provides the surrounding explanation.

required <- c("dplyr", "ggplot2", "readr", "scales", "here")
missing <- required[!vapply(required, requireNamespace, logical(1), quietly = TRUE)]
if (length(missing) > 0) stop("Install required packages: ", paste(missing, collapse = ", "))

library(dplyr)
library(ggplot2)
library(readr)
library(scales)
library(here)

out_dir <- here::here("visualisations")
dir.create(out_dir, recursive = TRUE, showWarnings = FALSE)

dat <- tibble::tribble(
  ~theme, ~topic, ~assignments,
  "Production", "Fish health > Sea lice control and treatment", 8L,
  "Production", "Fish health > Other diseases - General", 2L,
  "Production", "Fish health > Sea lice epidemiology", 2L,
  "Production", "Fish health > General fish health", 1L,
  "Production", "Fish health > Non-infectious disease and disorders", 1L,
  "Production", "Fish health > Other diseases - Epidemiology", 1L,
  "Production", "Fish health > Other diseases - Prevention and treatment", 1L,
  "Production", "Fish health > Sea lice impacts", 1L,
  "Production", "Feed and nutrition > Alternative feed ingredients", 3L,
  "Production", "Feed and nutrition > Feed additives and supplements", 2L,
  "Production", "Fish performance and biology > Physiology, metabolism and biological responses", 4L,
  "Production", "Fish welfare > Welfare assessment", 1L,
  "Production", "Production systems and technology > Integrated multi-trophic aquaculture", 1L,

  "Environment", "Wild populations and ecosystems > Parasite and pathogen transmission", 3L,
  "Environment", "Wild populations and ecosystems > Biodiversity and ecosystem effects", 1L,
  "Environment", "Resource use and footprint > Energy, greenhouse gases and life-cycle footprint", 2L,
  "Environment", "Resource use and footprint > Marine-resource use", 1L,
  "Environment", "Environmental management > Monitoring and assessment", 2L,
  "Environment", "Waste and emissions > Chemicals and therapeutants", 2L,
  "Environment", "Escapes > Escape occurrence and causes", 1L,

  "Methods", "Methodological research > Diagnostic and laboratory methods", 1L,
  "Methods", "Methodological research > Monitoring and sampling methods", 1L,
  "Methods", "Methodological research > Statistical and modelling methods", 1L,

  "Product", "Food safety > Microbial food safety", 2L,
  "Product", "Human nutrition and health > Nutritional benefits and risks", 1L,

  "Industry and governance", "Governance and policy > Licensing and spatial governance", 1L,
  "Industry and governance", "Markets, trade and value chains > Value chains and supply chains", 1L,

  "People and society", "Public health > Antimicrobial resistance and One Health", 1L
)

theme_order <- c(
  "Production", "Environment", "Methods",
  "Product", "Industry and governance", "People and society"
)

theme_cols <- c(
  "Production" = "#2c454a",
  "Environment" = "#89a5aa",
  "Methods" = "#e2b8a2",
  "Product" = "#f1a17f",
  "Industry and governance" = "#f47f5f",
  "People and society" = "#e55634"
)

dat <- dat %>%
  mutate(
    theme = factor(theme, levels = theme_order),
    row_id = row_number(),
    topic = factor(topic, levels = rev(topic))
  )

# Theme-centre positions and separators in the final top-to-bottom order.
plot_order <- dat %>% arrange(theme, row_id) %>% mutate(plot_row = rev(seq_len(n())))
theme_pos <- plot_order %>%
  group_by(theme) %>%
  summarise(
    y = mean(plot_row),
    ymin = min(plot_row),
    ymax = max(plot_row),
    .groups = "drop"
  )
separators <- theme_pos$ymin[-1] - 0.5

p <- ggplot(plot_order, aes(x = assignments, y = reorder(topic, plot_row), fill = theme)) +
  geom_col(width = 0.76) +
  geom_text(aes(label = assignments), hjust = -0.15, size = 3.0, colour = "#2c454a") +
  geom_hline(yintercept = separators, colour = "#cfd6d7", linewidth = 0.6) +
  scale_fill_manual(values = theme_cols, guide = "none") +
  scale_x_continuous(
    breaks = 0:8,
    limits = c(0, 9.0),
    expand = expansion(mult = c(0, 0))
  ) +
  coord_cartesian(clip = "off") +
  labs(x = NULL, y = NULL) +
  theme_minimal(base_size = 10) +
  theme(
    panel.grid.major.y = element_blank(),
    panel.grid.minor = element_blank(),
    panel.grid.major.x = element_line(colour = "#e1e5e6", linewidth = 0.35),
    axis.text.y = element_text(colour = "#2c454a", size = 8.3),
    axis.text.x = element_text(colour = "#577c84", size = 8.3),
    plot.margin = margin(6, 150, 6, 6),
    plot.background = element_rect(fill = "white", colour = NA),
    panel.background = element_rect(fill = "white", colour = NA)
  )

# Add theme labels to the right without an internal title/caption.
for (i in seq_len(nrow(theme_pos))) {
  p <- p + annotate(
    "text",
    x = 8.35,
    y = theme_pos$y[[i]],
    label = as.character(theme_pos$theme[[i]]),
    hjust = 0,
    fontface = "bold",
    size = 3.5,
    colour = "#2c454a"
  )
}

ggsave(
  file.path(out_dir, "figure_08_umbrella_review.pdf"),
  p, width = 210, height = 155, units = "mm", device = cairo_pdf
)
ggsave(
  file.path(out_dir, "figure_08_umbrella_review.png"),
  p, width = 210, height = 155, units = "mm", dpi = 600
)

write_csv(dat %>% mutate(theme = as.character(theme), topic = as.character(topic)),
          file.path(out_dir, "figure_08_umbrella_review_data.csv"))

message("Umbrella-review comparison figure written to: ", out_dir)
