# Load packages ----------------------------------------------------------------

source("global.R")

library(shiny)
library(bslib)
library(tidyverse)
library(tools)

source("bin_splits_module.R")

# Load data --------------------------------------------------------------------
# Get latest size data from Snowflake

#con <- DBI::dbConnect(
#  odbc::odbc(),
#  Driver            = "SnowflakeDSIIDriver",   # from Stage 1
#  Server            = "LWSDAPW-HR81165.snowflakecomputing.com",
#  warehouse         = "PROD_WH",
#  UID               = "POWERBISVC",
#  Authenticator     = "snowflake_jwt",
#  PRIV_KEY_FILE     = "C:/Users/StuartDykes/.snowflake/rsa_key_POWERBISVC.p8",
#  PRIV_KEY_FILE_PWD = Sys.getenv("SNOWFLAKE_KEY_PWD")
#)

#ApplePopSizeStats <- DBI::dbGetQuery(con, 
#                                     "SELECT 
#    AVG(MINOR) AS MEAN_EQ
#    ,STDDEV(MINOR) AS SD_EQ
#    ,AVG(MAJOR/MINOR) AS MEAN_ELONG
#    ,STDDEV(MAJOR/MINOR) AS SD_ELONG
#    ,AVG(WEIGHT) AS MEAN_MASS
#    ,STDDEV(WEIGHT) AS SD_MASS
#    ,COVAR_POP(MINOR,MAJOR/MINOR) AS COV
#FROM ROCKIT_DATA_PROD.COMPAC.STG_COMPAC_BATCH
#WHERE START_TIME > '2026-01-01 00:00:00.000' 
#AND START_TIME <= '2027-01-01 00:00:00.000' 
#AND NOT (SIZER_GRADE_NAME IN ('Capture','Rcy','Capture ','Recycle','Doub','Doubles ','Capt','Ai','Leaf','Cap'))
#AND MINOR >= 30
#AND MAJOR >= 30")

#DBI::dbDisconnect(con)

# Pre-compute defaults once so both UI and server can reference them  
defaults <- list(                                                      
  meanEQ   = round(ApplePopSizeStats$MEAN_EQ[[1]],   2),             
  sdEQ     = round(ApplePopSizeStats$SD_EQ[[1]],     2),             
  meanElong = round(ApplePopSizeStats$MEAN_ELONG[[1]], 3),           
  sdElong  = round(ApplePopSizeStats$SD_ELONG[[1]],  3),             
  cov      = round(ApplePopSizeStats$COV[[1]],        4)             
)                                                                      

# Define UI for random distribution app ----
# Sidebar layout with input and output definitions ----
ui <- page_sidebar(
  
  # App title ----
  title ="SKU Simulation tool",
  
  tags$style(HTML("                              /* <<< ADDED */
    .sidebar .control-label {                    /* label text */
      font-size: 0.75rem;
      margin-bottom: 0px;
    }
    .sidebar .form-control {                     /* the input box itself */
      font-size: 0.75rem;
      height: 26px;
      padding: 2px 6px;
    }
    .sidebar .shiny-input-container {            /* space between each input */
      margin-bottom: 4px;
    }
  ")),                                           
  
  # Sidebar panel for inputs ----
  sidebar = sidebar(
    
    tags$h2("Parameters for underlying distribution"),
    # Input: Select the random distribution type ----
    numericInput(
      inputId = "meanEQ",
      label = "Mean equatorial diameter",
      value = defaults$meanEQ, 
      min = 40,
      max = 80,
      step = 0.1
    ),
    # Input: Slider for the number of observations to generate ----
    numericInput(
      inputId = "sdEQ",
      label = "Standard deviation equatorial diameter",
      value = defaults$sdEQ, 
      min = 3,
      max = 6,
      step = 0.1
    ),
    numericInput(
      inputId = "meanElong",
      label = "Mean elongation",
      value = defaults$meanElong,
      min = 0.5,
      max = 1.2,
      step = 0.01
    ),
    numericInput(
      inputId = "sdElong",
      label = "Standard deviation elongation",
      value = defaults$sdElong,  
      min = 0.05,
      max = 0.3,
      step = 0.01
    ),
    numericInput(
      inputId = "cov",
      label = "covariance",
      value = defaults$cov,   
      min = -0.1,
      max = 0.1,
      step = 0.001
    ),
    actionButton(                                      # <<< ADDED
      inputId = "resetBtn",                           # <<< ADDED
      label   = "Reset to defaults",                  # <<< ADDED
      icon    = icon("rotate-left"),                  # <<< ADDED
      width   = "100%"                                # <<< ADDED
    )        
  ),
  
  # Main panel for displaying outputs ----
  # Output: A tabset that combines three panels ----
  navset_card_underline(
    nav_panel("Underlying distribution Plot", plotOutput("plot")),
    nav_panel("Bin splits", binSplitUI("bins")),
    nav_panel(
      "Batch analysis",
      layout_columns(
        col_widths = c(3, 9),
        card(
          card_header("Batch inputs"),
          radioButtons("batch_input_type", "Input type",
                       choices = c("Kilograms" = "kg", "Number of bins" = "bins"),
                       selected = "kg"),
          numericInput("batch_packout", "Packout / yield (%)",
                       value = 85, min = 0, max = 100, step = 0.5),
          tags$small(style = "color:grey;",
                     "Packout = Export kg / Input kg. SKU mix is derived from the current Bin splits configuration."),
          tags$hr(),
          uiOutput("batch_bin_kg_ui")
        ),
        layout_columns(
          col_widths = 12,
          card(
            card_header(
              "SKU output — RWEs by SKU",
              downloadButton("download_batch", "Export CSV",
                             style = "font-size:11px; height:28px; padding:3px 10px; float:right;")
            ),
            gt::gt_output("batch_table")
          ),
          card(
            card_header("SKU output — chart"),
            plotOutput("batch_chart", height = "300px")
          )
        )
      )
    )
  )
)

# Define server logic for random distribution app ----
server <- function(input, output, session) {
  
  # Reactive expression to generate the requested distribution ----
  # This is called whenever the inputs change. The output functions
  # defined below then use the value computed from this expression
  meq <- reactive({
    (input$meanEQ)
  })
  
  # Generate a plot of the data ----
  # Also uses the inputs to build the plot label. Note that the
  # dependencies on the inputs and the data reactive expression are
  # both tracked, and all expressions are called in the sequence
  # implied by the dependency graph.
  
  observeEvent(input$resetBtn, {                                         
    updateNumericInput(session, "meanEQ",    value = defaults$meanEQ)    
    updateNumericInput(session, "sdEQ",      value = defaults$sdEQ)      
    updateNumericInput(session, "meanElong", value = defaults$meanElong) 
    updateNumericInput(session, "sdElong",   value = defaults$sdElong)   
    updateNumericInput(session, "cov",       value = defaults$cov)       
  })  
  
  # Distribution parameter reactives -------------------------------------------
  # Defined separately so they can be passed to the bin splits module
  mu <- reactive({
    c(input$meanEQ, input$meanElong)
  })
  
  sigma <- reactive({
    matrix(
      c(input$sdEQ^2, input$cov,
        input$cov,    input$sdElong^2),
      nrow = 2
    )
  })
  
  # Simulate bivariate normal data ---------------------------------------------
  # Re-runs automatically whenever any numeric input changes
  simData <- reactive({
    sim <- MASS::mvrnorm(n = 1e6, mu = mu(), Sigma = sigma())
    data.frame(
      eq    = sim[, 1],
      elong = sim[, 2]
    )
  })
  
  # Plot -----------------------------------------------------------------------
  output$plot <- renderPlot({                                  
    ggplot(simData(), aes(x = elong, y = eq)) +               
      geom_bin2d(binwidth = c(0.005,0.5)) +   
      geom_vline(xintercept = input$meanElong, linewidth = 1, linetype = 2) +
      geom_hline(yintercept = input$meanEQ, linewidth = 1, linetype = 2) +
      scale_fill_viridis_c() +                 
      labs(                                                     
        x    = "Elongation",                       
        y    = "Equatorial diameter (mm)",                                 
        fill = "Count"                                         
      ) +    
      theme_minimal() +
      theme(legend.position = "none")
  })  
  
  module_out <- binSplitServer("bins", mean_vec = mu, cov_mat = sigma)
  bin_splits <- module_out$splits
  sku_probs  <- module_out$sku_probs

  # ── Batch analysis ──────────────────────────────────────────────────────────

  output$batch_bin_kg_ui <- renderUI({
    if (input$batch_input_type == "kg") {
      numericInput("batch_kg", "Input (kg)", value = 10000, min = 0, step = 100)
    } else {
      tagList(
        numericInput("batch_bins",   "Input (bins)",  value = 100, min = 0, step = 1),
        numericInput("batch_bin_kg", "kg per bin",    value = 300, min = 0, step = 10)
      )
    }
  })

  input_kg <- reactive({
    if (input$batch_input_type == "kg") {
      req(input$batch_kg);   input$batch_kg
    } else {
      req(input$batch_bins, input$batch_bin_kg)
      input$batch_bins * input$batch_bin_kg
    }
  })

  batch_result <- reactive({
    req(input$batch_packout)
    probs     <- sku_probs()
    total_kg  <- input_kg() * (input$batch_packout / 100)
    total_mw  <- sum(probs$mw_SKU)
    probs |>
      mutate(
        mass_share = mw_SKU / total_mw,
        rwe        = mass_share * total_kg
      ) |>
      select(SKU, mass_share, rwe) |>
      arrange(desc(rwe))
  })

  output$batch_table <- render_gt({
    df <- batch_result()
    df |>
      mutate(`Mass share` = scales::percent(mass_share, accuracy = 0.1),
             `RWEs`       = round(rwe, 0)) |>
      select(SKU, `Mass share`, `RWEs`) |>
      gt() |>
      grand_summary_rows(
        columns = `RWEs`,
        fns     = list(Total = ~ sum(.)),
        fmt     = ~ fmt_number(., decimals = 0, use_seps = TRUE)
      ) |>
      fmt_number(columns = `RWEs`, decimals = 0, use_seps = TRUE) |>
      cols_align("right", columns = c(`Mass share`, `RWEs`)) |>
      cols_align("left",  columns = SKU) |>
      opt_stylize(style = 1) |>
      opt_table_font(size = px(12)) |>
      tab_footnote(glue::glue("Based on {scales::comma(input_kg())} kg input at {input$batch_packout}% packout"))
  })

  output$download_batch <- downloadHandler(
    filename = function() {
      paste0("batch_rwe_", format(Sys.Date(), "%Y%m%d"), ".csv")
    },
    content = function(file) {
      batch_result() |>
        mutate(
          mass_share_pct = round(mass_share * 100, 2),
          rwe            = round(rwe, 1),
          input_kg       = input_kg(),
          packout_pct    = input$batch_packout
        ) |>
        select(SKU, mass_share_pct, rwe, input_kg, packout_pct) |>
        write_csv(file)
    }
  )

  output$batch_chart <- renderPlot({
    df       <- batch_result()
    sku_cols <- SKU_COLORS[df$SKU]
    sku_cols[is.na(sku_cols)] <- "grey60"
    ggplot(df, aes(x = reorder(SKU, rwe), y = rwe, fill = SKU)) +
      geom_col(width = 0.7) +
      geom_text(aes(label = scales::comma(rwe, accuracy = 1)),
                hjust = -0.15, size = 3.2) +
      scale_fill_manual(values = sku_cols, guide = "none") +
      scale_y_continuous(expand = expansion(mult = c(0, 0.18)),
                         labels = scales::comma) +
      coord_flip() +
      labs(x = NULL, y = "RWEs (kg)") +
      theme_minimal(base_size = 11) +
      theme(panel.grid.major.y = element_blank(),
            panel.grid.minor   = element_blank())
  })

}

shinyApp(ui = ui, server = server)