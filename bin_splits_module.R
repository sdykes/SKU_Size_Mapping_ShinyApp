# ── bin_splits_module.R ────────────────────────────────────────────────────────
# Shiny module: interactive bin split editor
# Returns a reactive named list: splits$`<bin_id>` = named numeric vector
#   e.g. splits$`29` = c("Daily small"=0.25, SFP=0.25, "63/5N"=0.25, "MB SNS"=0.25)
# ------------------------------------------------------------------------------

library(shiny)
library(bslib)
library(tidyverse)
library(base64enc)
library(gt)

# ── Data prep (run once at load time) ─────────────────────────────────────────

bin_grid <- read_csv("bin_grid_labelled.csv", show_col_types = FALSE) |>
  mutate(across(c(SKU, SKU2, SKU3, SKU4), str_trim),
         across(c(SKU, SKU2, SKU3, SKU4), ~replace_na(.,""))) |>
  rowwise() |>
  mutate(
    skus     = list(discard(c(SKU, SKU2, SKU3, SKU4), ~ .x == "")),
    n_skus   = length(skus),
    is_multi = n_skus > 1,
    is_empty = n_skus == 0
  ) |>
  mutate(
    primary_sku = if (length(skus) > 0) skus[[1]] else NA_character_
  ) |>
  ungroup()

mass_lookup <- read_csv("bin_mass_lookup.csv", show_col_types = FALSE)

bin_grid <- bin_grid |>
  left_join(
    mass_lookup,
    by = c("TomraElongBins" = "elong_idx", "EQBins" = "eq_idx")
  ) |>
  mutate(
    mean_mass_g = coalesce(mean_mass_g, median(mass_lookup$mean_mass_g, na.rm = TRUE))
  )

multi_bins <- bin_grid |> filter(is_multi)

# ── Default SKU proportions for multi-SKU bins ────────────────────────────────
# Edit these values to set the startup proportions.
# Keys are bin_id (as character); values are named numeric vectors summing to 1.
# Any multi-SKU bin NOT listed here will fall back to equal splits.
DEFAULT_SPLITS <- list(
  # Example entries – replace with your real bin_ids and SKU names:
  # "29" = c("Daily small" = 0.40, "SFP" = 0.35, "63/5N" = 0.25),
  # "42" = c("SFP" = 0.50, "LFP" = 0.50)
)

SKU_COLORS <- c(
  "Daily small" = "#1D9E75", "Daily large" = "#0F6E56",
  "SFP"         = "#378ADD", "LFP"         = "#185FA5",
  "63/5N"       = "#7F77DD", "Xlarge"      = "#D4537E",
  "MB SNS"      = "#BA7517", "MB LNS"      = "#854F0B",
  "MB XLNS"     = "#633806"
)

# ── Helper: rescale other sliders so all values sum to 1 ──────────────────────
# When slider `moved_i` changes to `new_val`, redistribute the remainder
# proportionally across the other sliders. If the other sliders are all zero,
# split the remainder equally among them.
rescale_splits <- function(current_vals, moved_i, new_val) {
  n         <- length(current_vals)
  remainder <- 1 - new_val
  others    <- setdiff(seq_len(n), moved_i)
  other_sum <- sum(current_vals[others])
  
  new_vals <- current_vals
  new_vals[moved_i] <- new_val
  
  if (other_sum > 0) {
    # preserve relative proportions of the other sliders
    new_vals[others] <- current_vals[others] / other_sum * remainder
  } else {
    # all others were zero — split remainder equally
    new_vals[others] <- remainder / length(others)
  }
  # guard against tiny floating point drift
  new_vals <- pmax(new_vals, 0)
  new_vals <- new_vals / sum(new_vals)
  new_vals
}

# ── Helper: P(apple falls in bin) via bivariate normal CDF ────────────────────
calc_bin_prob <- function(eq_low, eq_high, el_low, el_high, mean_vec, cov_mat) {
  # mvtnorm::pmvnorm expects lower/upper as [dim1, dim2] = [EQ, elong]
  prob <- mvtnorm::pmvnorm(
    lower = c(eq_low,  el_low),
    upper = c(eq_high, el_high),
    mean  = mean_vec,
    sigma = cov_mat
  )
  max(prob[[1]], 0)   # pmvnorm can return tiny negatives due to numerical error
}

# ── Module UI ─────────────────────────────────────────────────────────────────
binSplitUI <- function(id) {
  ns <- NS(id)
  tagList(
    tags$style(HTML(glue::glue("
      #{ns('grid_plot')} {{ cursor: crosshair; }}
      .split-panel {{ padding: 12px; }}
      .sku-badge {{
        display: inline-block; padding: 2px 8px; border-radius: 10px;
        font-size: 11px; font-weight: 500; color: white; margin-right: 4px;
      }}
    "))),
    navset_card_underline(
      # ── Tab 1: grid editor ──────────────────────────────────────────────────
      nav_panel(
        "Split editor",
        layout_columns(
          col_widths = c(7, 5),
          card(
            card_header("Bin assignment grid"),
            plotOutput(ns("grid_plot"), height = "480px",
                       click = clickOpts(id = ns("grid_click")))
          ),
          card(
            card_header(
              "SKU proportions",
              tooltip(
                bsicons::bs_icon("info-circle"),
                "Sliders only appear for multi-SKU bins. Moving one slider rescales the others to keep the total at 100%."
              )
            ),
            # ── Save / Load config row ──────────────────────────────────────
            tags$style(HTML(glue::glue("
              #{ns('save_config')}, #{ns('load_config_btn')} {{
                font-size: 11px; height: 28px; padding: 3px 10px; width: 100%;
              }}
              #{ns('file_input_hidden')} {{
                display: none;
              }}
            "))),
            tags$script(HTML(glue::glue("
              document.addEventListener('click', function(e) {{
                if (e.target && e.target.id === '{ns('load_config_btn')}') {{
                  document.getElementById('{ns('file_input_hidden')}').click();
                }}
              }});
              document.addEventListener('change', function(e) {{
                if (e.target && e.target.id === '{ns('file_input_hidden')}') {{
                  var file = e.target.files[0];
                  if (!file) return;
                  var reader = new FileReader();
                  reader.onload = function(ev) {{
                    Shiny.setInputValue('{ns('load_config_data')}',
                      {{ name: file.name, content: ev.target.result }},
                      {{ priority: 'event' }});
                  }};
                  reader.readAsDataURL(file);
                  e.target.value = '';
                }}
              }});
            "))),
            div(
              style = "display:flex; gap:6px; padding: 6px 12px 4px;",
              tags$input(id = ns("file_input_hidden"), type = "file", accept = ".rds"),
              downloadButton(ns("save_config"), "Save config"),
              actionButton(ns("load_config_btn"), "Load config",
                           icon = icon("folder-open"))
            ),
            uiOutput(ns("split_panel"))
          )
        )
      ),
      # ── Tab 2: summary table ────────────────────────────────────────────────
      nav_panel(
        "Split summary",
        card(
          card_header("All bin SKU proportions"),
          tableOutput(ns("split_table"))
        )
      ),
      nav_panel(
        "SKU probabilities",
        card(
          card_header(
            "Expected SKU distribution",
            downloadButton(ns("download_sku_probs"), "Export CSV",
                           style = "font-size:11px; height:28px; padding:3px 10px; float:right;")
          ),
          tags$p(style = "font-size:11px; color:grey; padding: 8px 12px 0;",
                 "Probability of a randomly selected apple being packed into each SKU, 
            given the current size distribution parameters and bin split configuration."),
          gt::gt_output(ns("sku_prob_table"))
        )
      )
    )
  )
}

# ── Module server ──────────────────────────────────────────────────────────────
binSplitServer <- function(id, mean_vec, cov_mat) {
  moduleServer(id, function(input, output, session) {
    ns <- session$ns
    
    eq_order <- c("US","58","63 S","63 M","63 L","2PC",
                  "67","67(66.4)","67(66.6)","67(66.8)","72","OS")
    
    plot_data <- bin_grid |>
      mutate(
        eq_idx   = match(EQBins, eq_order) - 1L,
        el_idx   = TomraElongBins,
        fill_col = case_when(
          is_empty ~ "grey92",
          TRUE     ~ coalesce(SKU_COLORS[primary_sku], "grey70")
        ),
        tile_alpha = case_when(
          is_empty ~ 0.15,
          is_multi ~ 0.90,
          TRUE     ~ 0.40
        )
      )
    
    # ── Reactive state ────────────────────────────────────────────────────────
    rv <- reactiveValues(
      selected_bin = NULL,
      splits = {
        sp <- list()
        walk(multi_bins$bin_id, function(bid) {
          skus <- multi_bins |> filter(bin_id == bid) |> pull(skus) |> first()
          n    <- length(skus)
          key  <- as.character(bid)
          
          if (!is.null(DEFAULT_SPLITS[[key]])) {
            # Use preset defaults; normalise just in case they don't sum to 1
            vals        <- DEFAULT_SPLITS[[key]]
            vals        <- vals / sum(vals)
          } else {
            vals        <- rep(1/n, n)
            names(vals) <- skus
          }
          sp[[key]] <- vals
        })
        sp
      },
      # track which slider was most recently moved per bin, to avoid loops
      last_moved = list()
    )
    
    # ── Heatmap plot ──────────────────────────────────────────────────────────
    output$grid_plot <- renderPlot({
      sel_bin <- rv$selected_bin
      highlight <- if (!is.null(sel_bin)) filter(plot_data, bin_id == sel_bin) else NULL
      
      p <- ggplot(plot_data,
                  aes(x = el_idx, y = eq_idx, fill = fill_col, alpha = tile_alpha)) +
        geom_tile(width = 0.92, height = 0.92, linewidth = 0.3, colour = "white") +
        scale_fill_identity() +
        scale_alpha_identity() +
        scale_x_continuous(breaks = 0:11, expand = c(0.02, 0)) +
        scale_y_continuous(breaks = 0:11, labels = eq_order, expand = c(0.02, 0)) +
        labs(x = "Elongation index", y = "Equatorial diameter bin") +
        theme_minimal(base_size = 11) +
        theme(
          panel.grid = element_blank(),
          axis.text.x = element_text(angle = 0, hjust = 0.5),
          plot.background = element_blank()
        )
      
      if (!is.null(highlight)) {
        p <- p + geom_tile(data = highlight, width = 0.92, height = 0.92,
                           fill = NA, colour = "white", linewidth = 2,
                           linetype = "solid", alpha = 1)
      }
      p
    }, bg = "transparent")
    
    # ── Click handler ──────────────────────────────────────────────────────────
    observeEvent(input$grid_click, {
      eq_clicked <- round(input$grid_click$y)
      el_clicked <- round(input$grid_click$x)
      
      hit <- bin_grid |>
        filter(
          match(EQBins, eq_order) - 1L == eq_clicked,
          TomraElongBins == el_clicked,
          is_multi
        )
      
      if (nrow(hit) == 1) rv$selected_bin <- hit$bin_id
    })
    
    # ── Split editor panel ────────────────────────────────────────────────────
    output$split_panel <- renderUI({
      bid <- rv$selected_bin
      
      if (is.null(bid)) {
        return(div(class = "split-panel",
                   tags$p(style = "color:grey; font-size:13px; margin-top:20px;",
                          "Click a solid (multi-SKU) bin on the grid to edit its SKU split.")))
      }
      
      bin_row <- filter(bin_grid, bin_id == bid)
      skus    <- bin_row$skus[[1]]
      current <- rv$splits[[as.character(bid)]]
      
      # fallback if not yet initialised
      if (is.null(current)) {
        n       <- length(skus)
        current <- rep(1/n, n)
        names(current) <- skus
        rv$splits[[as.character(bid)]] <- current
      }
      
      tagList(
        tags$p(style = "font-size:13px; font-weight:500; margin-bottom:4px;",
               glue::glue("Bin {bid} \u2014 {bin_row$EQBins} \u00d7 elong {bin_row$TomraElongBins}")),
        tags$p(style = "font-size:11px; color:grey; margin-bottom:12px;",
               glue::glue("{length(skus)} SKUs \u2014 moving one slider rescales the others to maintain 100%.")),
        
        map(seq_along(skus), function(i) {
          sku    <- skus[i]
          color  <- SKU_COLORS[sku] %||% "#888"
          inp_id <- ns(glue::glue("sl_{bid}_{i}"))
          
          #message("current class: ", class(current), " | length: ", length(current), " | names: ", paste(names(current), collapse=","))
          
          val <- as.numeric(current[[skus[i]]])[1]                          
          val <- if (is.null(val) || is.na(val)) 1/length(skus) else val
          
          tagList(
            tags$div(style = "display:flex; justify-content:space-between; margin-bottom:2px;",
                     tags$span(class = "sku-badge", style = glue::glue("background:{color};"), sku),
                     tags$span(style = "font-size:12px; font-weight:500;",
                               textOutput(ns(glue::glue("pct_{bid}_{i}")), inline = TRUE))
            ),
            sliderInput(inp_id, label = NULL,
                        min = 0, max = 1, step = 0.01,
                        value = round(val, 2)),
            tags$div(style = "margin-bottom:6px;")
          )
        }),
        
        tags$hr(style = "margin:8px 0;"),
        tags$div(
          style = "display:flex; justify-content:space-between; align-items:center;",
          tags$span(style = "font-size:12px; color:grey;", "Total"),
          tags$span(style = "font-size:13px; font-weight:500; color:green;", "100%")
        )
      )
    })
    
    # ── Constrained slider observers ──────────────────────────────────────────────
    observe({
      bid <- rv$selected_bin
      req(bid)
      
      skus <- filter(bin_grid, bin_id == bid)$skus[[1]]
      n    <- length(skus)
      
      # check all sliders exist before proceeding
      slider_vals <- map(seq_len(n), function(i) {
        input[[glue::glue("sl_{bid}_{i}")]]
      })
      req(all(!map_lgl(slider_vals, is.null)))   # bail if any slider not yet rendered
      
      slider_vals <- as.numeric(unlist(slider_vals))
      
      # find which slider moved by comparing to stored values
      stored <- isolate(rv$splits[[as.character(bid)]])
      req(!is.null(stored))
      stored_vals <- as.numeric(stored)
      
      diffs   <- abs(slider_vals - stored_vals)
      moved_i <- which.max(diffs)
      
      # only act if something actually changed
      if (max(diffs) < 0.001) return()
      
      updated        <- rescale_splits(stored_vals, moved_i, slider_vals[moved_i])
      names(updated) <- skus
      
      isolate(rv$splits[[as.character(bid)]] <- updated)
      
      # push rescaled values to the other sliders
      walk(setdiff(seq_len(n), moved_i), function(j) {
        updateSliderInput(session, glue::glue("sl_{bid}_{j}"),
                          value = round(unname(updated[j]), 2))
      })
    })
    
    # ── Per-SKU percentage labels ──────────────────────────────────────────────
    observe({
      bid <- rv$selected_bin
      req(bid)
      skus <- filter(bin_grid, bin_id == bid)$skus[[1]]
      walk(seq_along(skus), function(i) {
        local({
          li     <- i
          bid_l  <- bid
          out_id <- glue::glue("pct_{bid_l}_{li}")
          output[[out_id]] <- renderText({
            vals <- rv$splits[[as.character(bid_l)]]
            scales::percent(vals[li], accuracy = 1)
          })
        })
      })
    })
    
    # ── Summary table ──────────────────────────────────────────────────────────
    output$split_table <- renderTable({
      all_skus <- sort(unique(unlist(bin_grid$skus)))
      
      # Build one row per bin_id (all bins, not just multi)
      bin_grid |>
        arrange(bin_id) |>
        rowwise() |>
        mutate(
          SKU_list = paste(skus, collapse = " / "),
          Type = case_when(
            is_empty ~ "Unassigned",
            is_multi ~ "Multi-SKU",
            TRUE     ~ "Single-SKU"
          )
        ) |>
        ungroup() |>
        select(bin_id, EQBins, TomraElongBins, Type, SKU_list) |>
        bind_cols(
          # one column per unique SKU showing the proportion
          map_dfc(all_skus, function(sku) {
            col_vals <- map_dbl(seq_len(nrow(bin_grid)), function(row_i) {
              bid  <- bin_grid$bin_id[row_i]
              skus <- bin_grid$skus[[row_i]]
              
              if (!(sku %in% skus)) return(NA_real_)
              
              if (length(skus) == 1) return(1)
              
              sp <- rv$splits[[as.character(bid)]]
              if (!is.null(sp) && sku %in% names(sp)) sp[sku] else 1/length(skus)
            })
            tibble(!!sku := col_vals)
          })
        ) |>
        # format proportions as percentages, leave NA as blank
        mutate(across(all_of(all_skus), ~ if_else(
          is.na(.x), "",
          scales::percent(.x, accuracy = 1)
        ))) |>
        rename(
          `Bin ID`     = bin_id,
          `EQ bin`     = EQBins,
          `Elong bin`  = TomraElongBins,
          `SKU(s)`     = SKU_list
        )
    }, striped = TRUE, hover = TRUE, bordered = TRUE, spacing = "s",
    na = "")
    
    # ── SKU probability calculation ───────────────────────────────────────────────
    sku_probs <- reactive({
      mv <- mean_vec()
      cm <- cov_mat()
      
      # Step 1: P(bin) for every bin, with mass weight
      bin_probs <- bin_grid |>
        mutate(
          p_bin = pmap_dbl(
            list(EQCutsLow, EQCutsHigh, ElongBreaksLow, ElongBreaksHigh),
            function(eq_lo, eq_hi, el_lo, el_hi) {
              calc_bin_prob(eq_lo, eq_hi, el_lo, el_hi, mv, cm)
            }
          ),
          mass_wt = p_bin * mean_mass_g   # mass-weighted probability
        )
      
      # Step 2: expand to one row per bin×SKU, weighted by split proportion
      bin_probs |>
        filter(!is_empty) |>
        rowwise() |>
        mutate(
          sku_split = list({
            bid <- bin_id
            if (is_multi) {
              sp <- rv$splits[[as.character(bid)]]
              if (is.null(sp)) {
                vals <- rep(1/n_skus, n_skus); names(vals) <- skus; vals
              } else sp
            } else {
              vals <- 1; names(vals) <- skus[[1]]; vals
            }
          })
        ) |>
        ungroup() |>
        select(bin_id, p_bin, mass_wt, sku_split) |>
        mutate(
          sku_rows = pmap(list(p_bin, mass_wt, sku_split), function(p, mw, sp) {
            tibble(
              SKU        = names(sp),
              p_contrib  = p  * as.numeric(sp),
              mw_contrib = mw * as.numeric(sp)
            )
          })
        ) |>
        select(sku_rows) |>
        unnest(sku_rows) |>
        
        # Step 3: aggregate by SKU
        group_by(SKU) |>
        summarise(
          p_SKU  = sum(p_contrib),
          mw_SKU = sum(mw_contrib),
          .groups = "drop"
        ) |>
        arrange(desc(p_SKU))
    })
    
    output$sku_prob_table <- render_gt({
      df <- sku_probs()
      
      # US / OS — both count and mass weighted
      mv <- mean_vec()
      cm <- cov_mat()

      us_os_probs <- bin_grid |>
        filter(EQBins %in% c("US", "OS")) |>
        mutate(
          p_bin  = pmap_dbl(
            list(EQCutsLow, EQCutsHigh, ElongBreaksLow, ElongBreaksHigh),
            function(eq_lo, eq_hi, el_lo, el_hi) {
              calc_bin_prob(eq_lo, eq_hi, el_lo, el_hi, mv, cm)
            }
          ),
          mw_bin = p_bin * mean_mass_g
        ) |>
        group_by(EQBins) |>
        summarise(p_total = sum(p_bin), mw_total = sum(mw_bin), .groups = "drop")

      p_us  <- us_os_probs |> filter(EQBins == "US") |> pull(p_total)  |> sum()
      p_os  <- us_os_probs |> filter(EQBins == "OS") |> pull(p_total)  |> sum()
      mw_us <- us_os_probs |> filter(EQBins == "US") |> pull(mw_total) |> sum()
      mw_os <- us_os_probs |> filter(EQBins == "OS") |> pull(mw_total) |> sum()

      p_assigned <- sum(bin_grid |>
        filter(!is_empty) |>
        mutate(p_bin = pmap_dbl(
          list(EQCutsLow, EQCutsHigh, ElongBreaksLow, ElongBreaksHigh),
          function(eq_lo, eq_hi, el_lo, el_hi) {
            calc_bin_prob(eq_lo, eq_hi, el_lo, el_hi, mv, cm)
          }
        )) |>
        filter(!EQBins %in% c("US", "OS")) |>
        pull(p_bin))

      total_p_all  <- sum(df$p_SKU) + p_us + p_os
      total_p_pac  <- sum(df$p_SKU)
      total_mw_all <- sum(df$mw_SKU) + mw_us + mw_os
      total_mw_pac <- sum(df$mw_SKU)

      packed_rows <- df |>
        transmute(
          SKU,
          p_abs  = p_SKU  / total_p_all,
          p_pac  = p_SKU  / total_p_pac,
          mw_abs = mw_SKU / total_mw_all,
          mw_pac = mw_SKU / total_mw_pac
        )

      footer_rows <- tibble(
        SKU    = c("Undersize (US)", "Oversize (OS)", "Other unassigned"),
        p_abs  = c(p_us / total_p_all,   p_os / total_p_all,   max(1 - p_assigned - p_us - p_os, 0)),
        p_pac  = NA_real_,
        mw_abs = c(mw_us / total_mw_all, mw_os / total_mw_all, NA_real_),
        mw_pac = NA_real_
      )
      
      bind_rows(packed_rows, footer_rows) |>
        gt() |>
        tab_spanner(label = "By apple count", columns = c(p_abs, p_pac)) |>
        tab_spanner(label = "By mass",        columns = c(mw_abs, mw_pac)) |>
        cols_label(
          SKU    = "SKU",
          p_abs  = "% of all fruit",
          p_pac  = "% of packed",
          mw_abs = "% of all fruit",
          mw_pac = "% of packed"
        ) |>
        fmt(columns = c(p_abs, p_pac, mw_abs, mw_pac),
            fns = function(x) dplyr::if_else(is.na(x), "—",
                                              scales::percent(x, accuracy = 0.1))) |>
        tab_style(
          style    = cell_borders(sides = "left", weight = px(2), color = "grey70"),
          locations = cells_body(columns = mw_abs)
        ) |>
        tab_style(
          style    = cell_borders(sides = "left", weight = px(2), color = "grey70"),
          locations = cells_column_labels(columns = mw_abs)
        ) |>
        cols_align("center", columns = c(p_abs, p_pac, mw_abs, mw_pac)) |>
        opt_stylize(style = 1) |>
        opt_table_font(size = px(12))
    })
    
    
    # ── Save config ───────────────────────────────────────────────────────────
    output$save_config <- downloadHandler(
      filename = function() {
        paste0("sku_config_", format(Sys.Date(), "%Y%m%d"), ".rds")
      },
      content = function(file) {
        saveRDS(isolate(rv$splits), file)
      }
    )
    
    # ── Load config ───────────────────────────────────────────────────────────
    observeEvent(input$load_config_data, {
      req(input$load_config_data)
      
      # Decode base64 data URL to raw bytes, write to a temp file, then readRDS
      data_url <- input$load_config_data$content
      b64      <- sub("^data:[^;]+;base64,", "", data_url)
      raw_data <- tryCatch(base64enc::base64decode(b64), error = function(e) NULL)
      
      if (is.null(raw_data)) {
        showNotification("Failed to decode file.", type = "error", duration = 5)
        return()
      }
      
      tmp    <- tempfile(fileext = ".rds")
      writeBin(raw_data, tmp)
      loaded <- tryCatch(readRDS(tmp), error = function(e) NULL)
      unlink(tmp)
      
      if (is.null(loaded) || !is.list(loaded)) {
        showNotification("Could not read config file — please load a valid .rds saved from this tool.",
                         type = "error", duration = 5)
        return()
      }
      
      valid_keys <- as.character(multi_bins$bin_id)
      walk(intersect(names(loaded), valid_keys), function(key) {
        vals <- loaded[[key]]
        rv$splits[[key]] <- vals / sum(vals)
      })
      
      showNotification(
        glue::glue("Loaded {length(intersect(names(loaded), valid_keys))} bin configurations."),
        type = "message", duration = 3
      )
    })
    
    # ── Download SKU probabilities CSV ───────────────────────────────────────
    output$download_sku_probs <- downloadHandler(
      filename = function() {
        paste0("sku_probabilities_", format(Sys.Date(), "%Y%m%d"), ".csv")
      },
      content = function(file) {
        df <- sku_probs()
        mv <- mean_vec()
        cm <- cov_mat()

        us_os_probs <- bin_grid |>
          filter(EQBins %in% c("US", "OS")) |>
          mutate(
            p_bin  = pmap_dbl(
              list(EQCutsLow, EQCutsHigh, ElongBreaksLow, ElongBreaksHigh),
              function(eq_lo, eq_hi, el_lo, el_hi) {
                calc_bin_prob(eq_lo, eq_hi, el_lo, el_hi, mv, cm)
              }
            ),
            mw_bin = p_bin * mean_mass_g
          ) |>
          group_by(EQBins) |>
          summarise(p_total = sum(p_bin), mw_total = sum(mw_bin), .groups = "drop")

        p_us  <- us_os_probs |> filter(EQBins == "US") |> pull(p_total)  |> sum()
        p_os  <- us_os_probs |> filter(EQBins == "OS") |> pull(p_total)  |> sum()
        mw_us <- us_os_probs |> filter(EQBins == "US") |> pull(mw_total) |> sum()
        mw_os <- us_os_probs |> filter(EQBins == "OS") |> pull(mw_total) |> sum()

        total_p_all  <- sum(df$p_SKU) + p_us + p_os
        total_p_pac  <- sum(df$p_SKU)
        total_mw_all <- sum(df$mw_SKU) + mw_us + mw_os
        total_mw_pac <- sum(df$mw_SKU)

        packed_rows <- df |>
          transmute(
            SKU,
            pct_all_fruit_count  = round(p_SKU  / total_p_all  * 100, 2),
            pct_packed_count     = round(p_SKU  / total_p_pac  * 100, 2),
            pct_all_fruit_mass   = round(mw_SKU / total_mw_all * 100, 2),
            pct_packed_mass      = round(mw_SKU / total_mw_pac * 100, 2)
          )

        footer_rows <- tibble(
          SKU                  = c("Undersize (US)", "Oversize (OS)", "Other unassigned"),
          pct_all_fruit_count  = round(c(p_us / total_p_all,   p_os / total_p_all,   max(1 - sum(df$p_SKU + p_us + p_os), 0)) * 100, 2),
          pct_packed_count     = NA_real_,
          pct_all_fruit_mass   = round(c(mw_us / total_mw_all, mw_os / total_mw_all, NA_real_) * 100, 2),
          pct_packed_mass      = NA_real_
        )

        bind_rows(packed_rows, footer_rows) |>
          write_csv(file, na = "")
      }
    )

    # ── Return splits reactive ─────────────────────────────────────────────────
    return(list(splits = reactive(rv$splits), sku_probs = sku_probs))
  })
}