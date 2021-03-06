context("rSOILWAT2 water balance")

# The 8 checks, implemented below, correspond to the checks in
# \var{SOILWAT/test/test_WaterBalance.cc}


#---CONSTANTS
tol <- 10 ^ (-rSW2_glovars[["kSOILWAT2"]][["kINT"]][["OUT_DIGITS"]])
SW_OUTNPERIODS <- rSW2_glovars[["kSOILWAT2"]][["kINT"]][["SW_OUTNPERIODS"]]
OutPeriods <- rSW2_glovars[["sw_TimeSteps"]]
veg_types <- c("tree", "shrub", "forbs", "grass")
dir_test_data <- file.path("..", "test_data")
temp <- list.files(dir_test_data, pattern = "Ex")
temp <- sapply(strsplit(temp, "_"), function(x) x[[1]])
tests <- unique(temp)
test_that("Test data availability", expect_gt(length(tests), 0))

aggregate_for_each_timestep <- function(x, dyt) {
  nid <- 1:2
  list(
    Day = x,
    Week = {
      temp <- if (NCOL(x) > 1) x[dyt[["nfw"]] - 1, ] else x[dyt[["nfw"]] - 1]
      temp <- aggregate(temp, by = dyt[["d"]][dyt[["nfw"]], c("Week", "Year")],
        FUN = sum)
      temp <- temp[, -nid]
    },
    Month = {
      temp <- if (NCOL(x) > 1) x[dyt[["nfm"]] - 1, ] else x[dyt[["nfm"]] - 1]
      temp <- aggregate(temp, by = dyt[["d"]][dyt[["nfm"]], c("Month", "Year")],
        FUN = sum)
      temp <- temp[, -nid]
    },
    Year = {
      temp <- if (NCOL(x) > 1) x[dyt[["nfy"]] - 1, ] else x[dyt[["nfy"]] - 1]
      temp <- aggregate(temp, by = list(dyt[["d"]][dyt[["nfy"]], "Year"]),
        FUN = sum)
      temp <- temp[, -1]
    })
}


for (it in tests) {
  #---INPUTS
  sw_weather <- readRDS(file.path(dir_test_data, paste0(it, "_weather.rds")))
  sw_input <- readRDS(file.path(dir_test_data, paste0(it, "_input.rds")))

  # Request summed values for every time step
  swOUT_TimeStepsForEveryKey(sw_input) <- seq_len(SW_OUTNPERIODS) - 1
  slot(slot(sw_input, "output"), "sumtype")[] <- 1L

  #---TESTS
  info1 <- paste("test-data:", it)

  test_that("Water balance & cycle", {
    # Run SOILWAT
    x <- sw_exec(inputData = sw_input, weatherList = sw_weather, echo = FALSE,
      quiet = TRUE)
    expect_s4_class(x, "swOutput")


    # Get state change values which are directly re-aggregated from daily data
    N <- slot(x, "dy_nrow")
    Ns <- seq_len(N)
    idelta1 <- Ns[-N]
    idelta2 <- Ns[-1]

    temp <- slot(slot(x, "SURFACEWATER"), "Day")
    surfaceWater <- temp[, "surfaceWater_cm"]

    dates <- data.frame(temp[, c("Year", "Day")])
    dates[, "DOY"] <- dates[, "Day"]
    temp <- as.POSIXlt(seq.Date(
      from = as.Date(ISOdate(dates[1, "Year"], 1, 1)),
      to = as.Date(ISOdate(dates[nrow(dates), "Year"], 12, 31)), by = "day"))
    dates[, "Month"] <- 1 + temp$mon
    dates[, "Day"] <- temp$mday
    # SOILWAT2 'weeks' are not calendar weeks as in
    #   \code{as.integer(format(temp, "%W"))}
    #   with \code{%U = US weeks}; \coe{%V = ISO 8601}; \code{%W = UK weeks}
    # instead SOILWAT2 numbers consecutive sets of 7-day periods
    dates[, "Week"] <- 1 + (dates[, "DOY"] - 1) %/% 7
    dyt <- list(d = dates, ids1 = idelta1, ids2 = idelta2,
      # not first year:
      nfy = which(temp <- dates[, "Year"] != dates[1, "Year"]),
      # not first month of first year:
      nfm = which(temp | dates[, "Month"] != dates[1, "Month"]),
      # not first week of first year:
      nfw = which(temp | dates[, "Week"] != dates[1, "Week"])
    )

    # change in ponded (surface) water
    list_delta_surfaceWater <- aggregate_for_each_timestep(
      x = surfaceWater[dyt[["ids2"]]] - surfaceWater[dyt[["ids1"]]],
      dyt)

    # change in soil moisture
    temp <- slot(slot(x, "SWCBULK"), "Day")
    swcj <- temp[, grep("Lyr", colnames(temp)), drop = FALSE]
    n_soillayers <- ncol(swcj)

    # today - yesterday:
    dy_delta_swcj <- swcj[dyt[["ids2"]], ] - swcj[dyt[["ids1"]], ]
    list_delta_swcj <- aggregate_for_each_timestep(x = dy_delta_swcj, dyt)
    list_delta_swc_total <- aggregate_for_each_timestep(
      x = apply(dy_delta_swcj, 1, sum),
      dyt)


    # Loop through time steps
    for (pd in seq_len(SW_OUTNPERIODS)) {
      info2 <- paste(info1, "/ time step:", OutPeriods[pd])

      # Get values
      aet <- slot(slot(x, "AET"), OutPeriods[pd])[, "evapotr_cm"]
      pet <- slot(slot(x, "PET"), OutPeriods[pd])[, "pet_cm"]

      temp <- seq_along(aet)
      idelta1 <- temp[-length(temp)]
      idelta2 <- temp[-1]

      # Get evaporation values
      temp <- slot(slot(x, "EVAPSURFACE"), OutPeriods[pd])
      Etotalsurf <- temp[, "evap_total"]
      Elitter <- temp[, "evap_litter"]
      Eponded <- temp[, "evap_surfaceWater"]
      Evegi <- temp[, paste0("evap_", veg_types), drop = FALSE]
      Eveg <- apply(Evegi, 1, sum)
      Etotalint <- Eveg + Elitter

      temp <- slot(slot(x, "EVAPSOIL"), OutPeriods[pd])
      Esoilj <- temp[, grep("Lyr", colnames(temp)), drop = FALSE]
      Esoil <- apply(Esoilj, 1, sum)

      temp <- matrix(0, nrow = nrow(Esoilj), ncol = n_soillayers)
      temp[, seq_len(ncol(Esoilj))] <- Esoilj
      Esoilj <- temp

      Esnow <- slot(slot(x, "PRECIP"), OutPeriods[pd])[, "snowloss"]
      Etotal <- Etotalsurf + Esoil + Esnow

      # Get transpiration values
      temp <- slot(slot(x, "TRANSP"), OutPeriods[pd])
      Ttotalj <- temp[, grep("transp_total_Lyr", colnames(temp)), drop = FALSE]
      Ttotal <- apply(Ttotalj, 1, sum)
      Tvegij <- lapply(veg_types, function(v)
        temp[, grep(paste0("transp_", v, "_Lyr"), colnames(temp)),
          drop = FALSE])
      names(Tvegij) <- veg_types

      # Get other water flux values
      infiltration <- slot(slot(x, "SOILINFILT"),
        OutPeriods[pd])[, "soil_inf"]
      deepDrainage <- slot(slot(x, "DEEPSWC"),
        OutPeriods[pd])[, "lowLayerDrain_cm"]

      temp <- slot(slot(x, "LYRDRAIN"), OutPeriods[pd])
      temp <- temp[, grep("Lyr", colnames(temp)), drop = FALSE]
      percolationIn <- cbind(infiltration, temp)
      percolationOut <- cbind(temp, deepDrainage)

      temp <- slot(slot(x, "HYDRED"), OutPeriods[pd])
      ctemp <- grep("total_Lyr", colnames(temp))
      hydraulicRedistribution <- temp[, ctemp, drop = FALSE]

      temp <- slot(slot(x, "INTERCEPTION"), OutPeriods[pd])
      intercepted <- temp[, "int_total"]

      temp <- slot(slot(x, "RUNOFF"), OutPeriods[pd])
      ctemp <- grep("runoff", colnames(temp))
      runoff <- apply(temp[, ctemp, drop = FALSE], 1, sum)
      ctemp <- grep("runon", colnames(temp))
      runon <- apply(temp[, ctemp, drop = FALSE], 1, sum)

      temp <- slot(slot(x, "PRECIP"), OutPeriods[pd])
      snowmelt <- temp[, "snowmelt"]
      rain <- temp[, "rain"]

      arriving_water <- rain + snowmelt + runon


      # Get state change values
      delta_surfaceWater <- list_delta_surfaceWater[[OutPeriods[pd]]]
      delta_swcj <- list_delta_swcj[[OutPeriods[pd]]]
      delta_swc_total <- list_delta_swc_total[[OutPeriods[pd]]]

      #--- Water balance checks
      # (1) \code{AET <= PET}
      expect_true(all(aet < pet | abs(pet - aet) < tol), info = info2)

      # (2) \code{AET == E(total) + T(total)}
      expect_equal(aet, Etotal + Ttotal, info = info2)

      # (3) \code{T(total) = sum of T(veg-type i from soil layer j)}
      expect_equal(Ttotal, apply(sapply(Tvegij, function(x) apply(x, 1, sum)),
        1, sum), info = info2)

      # (4) \code{E(total) = E(total bare-soil) + E(ponded water) +
      #              + E(total litter-intercepted) + E(total veg-intercepted) +
      #              + E(snow sublimation)}
      expect_equal(Etotal, Esoil + Eponded + Eveg + Elitter + Esnow,
        info = info2)

      # (5) \code{E(total surface) = E(ponded water) +
      #           + E(total litter-intercepted) + E(total veg-intercepted)}
      expect_equal(Etotalsurf, Eponded + Eveg + Elitter, info = info2)


      #--- Water cycling checks
      # (6) \code{infiltration = [rain + snowmelt + runon] -
      #                (runoff + intercepted + delta_surfaceWater + Eponded)}
      expect_equal(infiltration[idelta2], arriving_water[idelta2] -
        (runoff[idelta2] + intercepted[idelta2] + delta_surfaceWater +
        Eponded[idelta2]), info = info2)

      # (7) \code{E(soil) + Ttotal = infiltration - (deepDrainage + delta(swc))}
      expect_equal(Esoil[idelta2] + Ttotal[idelta2],
        infiltration[idelta2] - (deepDrainage[idelta2] + delta_swc_total),
        info = info2)

      # (8) for every soil layer j: \code{delta(swc) =
      #   = infiltration/percolationIn + hydraulicRedistribution -
      #     (percolationOut/deepDrainage + transpiration + evaporation)}
      for (j in seq_len(n_soillayers)) {
        expect_equal(delta_swcj[, j],
          percolationIn[idelta2, j] + hydraulicRedistribution[idelta2, j] -
          (percolationOut[idelta2, j] + Ttotalj[idelta2, j] +
          Esoilj[idelta2, j]), info = paste(info2, "/ soil layer:", j))
      }
    }
  })
}
