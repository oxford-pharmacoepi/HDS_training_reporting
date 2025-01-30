dbName <- "CPRD GOLD"
server_dbi <- "cdm_gold_202407"
port<-Sys.getenv("DB_PORT")
host<-Sys.getenv("DB_HOST")
user<-Sys.getenv("DB_USER")
password<-Sys.getenv("DB_PASSWORD")

db <- DBI::dbConnect(RPostgres::Postgres(),
                     dbname = server_dbi,
                     port = port,
                     host = host,
                     user = user,
                     password = password)

cdmSchema <- "public_100k"
writeSchema <- "results"
writePrefix <- "mcs_"

cdm <- CDMConnector::cdmFromCon(
  con = db, 
  cdmSchema = cdmSchema, 
  writeSchema = writeSchema, 
  cdmName = dbName,
  writePrefix = writePrefix
)

studyPeriod <- as.Date(c("2010-01-01", "2019-12-31"))
ageGroup <- list(c(0, 19), c(20, 39), c(40, 59), c(60, 79), c(80, 150))
strata <- list("age_group", "sex", c("age_group", "sex"))

ingredients <- c("tramadol", "codeine", "amoxicillin", "azithromycin", "metformin")
drugs <- CodelistGenerator::getDrugIngredientCodes(cdm = cdm, name = ingredients, nameStyle = "{concept_name}")
medications <- CodelistGenerator::getATCCodes(cdm = cdm)
names(medications) <- omopgenerics::toSnakeCase(names(medications))
conditions <- CodelistGenerator::getICD10StandardCodes(cdm = cdm, level = "ICD10 Chapter")
names(conditions) <- omopgenerics::toSnakeCase(names(conditions))

cdm <- DrugUtilisation::generateDrugUtilisationCohortSet(
  cdm = cdm, name = "ingredients", conceptSet = drugs, gapEra = 30
)

cdm$new_ingredients <- cdm$ingredients |>
  DrugUtilisation::requireObservationBeforeDrug(days = 365, name = "new_ingredients") |>
  DrugUtilisation::requirePriorDrugWashout(days = 365) |>
  DrugUtilisation::requireDrugInDateRange(dateRange = studyPeriod) |>
  PatientProfiles::addDemographics(
    age = FALSE, ageGroup = ageGroup, sex = TRUE, priorObservation = FALSE, futureObservation = FALSE, name = "new_ingredients"
  )

cdm$medications <- CohortConstructor::conceptCohort(
  cdm = cdm, conceptSet = medications, name = "medications", subsetCohort = "new_ingredients"
)

cdm$conditions <- CohortConstructor::conceptCohort(
  cdm = cdm, conceptSet = conditions, name = "conditions", subsetCohort = "new_ingredients"
)

attrition <- CohortCharacteristics::summariseCohortAttrition(cdm$new_ingredients)

patientsCovered <- cdm$new_ingredients |>
  DrugUtilisation::summariseProportionOfPatientsCovered(
    strata = strata, 
    followUpDays = 365
  )

characteristics <- cdm$new_ingredients |>
  CohortCharacteristics::summariseCharacteristics(
    demographics = TRUE,
    strata = strata, 
    ageGroup = ageGroup, 
    cohortIntersectFlag = list(
      "Medications in the year prior" = list(
        targetCohortTable = "medications", window = c(-365, -1)
      ),
      "Conditions any time prior" = list(
        targetCohortTable = "conditions", window = c(-365, -1)
      )
    ),
    tableIntersectCount = list(
      "Number of visits in the year prior" = list(
        tableName = "visit_occurrence", window = c(-365, -1)
      )
    )
  )

cdm <- IncidencePrevalence::generateDenominatorCohortSet(
  cdm = cdm, 
  name = "denominator", 
  cohortDateRange = studyPeriod, 
  ageGroup = c(list(c(0, 150)), ageGroup), 
  sex = c("Male", "Female", "Both")
)

prevalence <- IncidencePrevalence::estimatePeriodPrevalence(
  cdm = cdm, 
  denominatorTable = "denominator", 
  outcomeTable = "ingredients", 
  interval = "years", 
  completeDatabaseIntervals = TRUE
)

omopgenerics::exportSummarisedResult(
  attrition,
  patientsCovered,
  characteristics,
  prevalence,
  fileName = "hds_training_results.csv",
  path = here::here(),
  minCellCount = 5
)
