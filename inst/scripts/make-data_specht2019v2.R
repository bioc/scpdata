
####---- Specht et al. 2019 ---####


## Specht, Harrison, Edward Emmott, Toni Koller, and Nikolai Slavov. 2019. 
## “High-Throughput Single-Cell Proteomics Quantifies the Emergence of Macrophage 
## Heterogeneity.” bioRxiv. https://doi.org/10.1101/665307.

## NOTE: the script is version 2 because the data set was updated by the authors

library(SingleCellExperiment)
library(scp)
library(tidyverse)
dataDir <- "~/PhD/.localdata/SCP/specht2019/v2/"

####---- Load PSM data ----####

## The files were downloaded from 
## https://drive.google.com/drive/folders/1VzBfmNxziRYqayx3SP-cOe2gu129Obgx
## ev = the MaxQuant output file for all batches with the PSM data
ev <- read.csv(paste0(dataDir, "evidence_unfiltered.csv"), 
               sep = ",", header = TRUE)
## design = the cell annotation
design <- read.csv(paste0(dataDir, "annotation.csv"), 
                   check.names = FALSE)
## batch = the batch annotation 
batch <- read.csv(paste0(dataDir, "batch.csv"), 
                  check.names = FALSE)

## Clean the sample metadata so that it meets the requirements for
## `scp::readSCP`. The cell annotation and batch annotation are merge into a 
## table
inner_join(x = design %>% 
             pivot_longer(-Set, 
                          names_to = "Channel", 
                          values_to = "SampleAnnotation") %>%
             mutate(SampleType = recode(SampleAnnotation, 
                                        sc_0 = "Blank",
                                        sc_u = "Monocyte",
                                        sc_m0 = "Macrophage",
                                        unused = "Unused",
                                        norm = "Reference",
                                        reference = "Reference",
                                        carrier_mix = "Carrier")) %>%
             mutate_all(as.character), 
           y = batch %>% rename(Set = set) %>%
             mutate_all(as.character),
           by = "Set") -> 
  meta

## Clean quantitative data
ev %>%
  ## Remove variable not related to PSM info
  select(-c("X", "X1", "lcbatch", "sortday",  "digest")) %>%
  ## channel naming should be consistent with metadata
  rename_all(gsub, 
             pattern = "^Reporter[.]intensity[.](\\d*)$", 
             replacement = "RI\\1") %>%
  ## MS set should be consistent with metadata and other data
  rename(Set = Raw.file, 
         peptide = modseq,
         protein = Leading.razor.protein) %>%
  ## Remove "X" at start of batch 
  mutate(Set = gsub("^X", "", Set)) %>%
  ## keep only single cell runs 
  filter(!grepl("col\\d{2}|arrier|Ref|Master|SQC|blank", Set)) %>%
  ## remove experimental sets concurrent with low mass spec performance
  filter(!grepl("FP9[56]|FP103", Set)) %>%
  ## Make sure all runs are described in design, if not, remove them
  filter(Set %in% meta$Set) %>%
  ## Keep only useful information 
  select(Set, peptide, protein, matches("RI[0-9]*$"), Sequence, Length, 
         Modified.sequence, Charge, m.z, Mass, Resolution, Missed.cleavages, 
         Gene.names, Protein.names, PIF, Score, PEP, dart_PEP, dart_qval) ->
  ev
  
## Create the QFeatures object
specht2019v2 <- readSCP(ev, 
                        meta, 
                        channelCol = "Channel", 
                        batchCol = "Set",
                        removeEmptyCols = TRUE)

####---- Include the peptide data ----####

## The `Peptides-raw.csv` and `Cells.csv` files were downloaded from 
## https://scope2.slavovlab.net/docs/data.
## The `id_to_channel.RData` file was generated using the `SCoPE2_analysis.R`
## script from https://github.com/cvanderaa/SCoPE2/tree/1483b8e4e5e55a77ed2813133f89f415c0403437/code

## Get batch annotation
read.csv(paste0(dataDir, "Cells.csv"), row.names = 1) %>%
  t %>%
  as.data.frame %>%
  rownames_to_column("id") %>%
  rename(Set = raw.file, SampleAnnotation = celltype, digest = batch_digest, 
         sortday = batch_sort, lcbatch = batch_chromatography) %>%
  mutate(Channel = NA, 
         Set = sub("^X", "", Set),
         SampleType = recode(SampleAnnotation, 
                             sc_0 = "Blank",
                             sc_u = "Monocyte",
                             sc_m0 = "Macrophage",
                             unused = "Unused",
                             norm = "Reference",
                             reference = "Reference",
                             carrier_mix = "Carrier")) %>%
  column_to_rownames("id") %>%
  as("DataFrame") ->
  annot
## Get cell to add to reference channel annotation
## `IDtoChannel.csv` contains the id to channel index mapping
read.csv(paste0(dataDir, "IDtoChannel.csv")) %>%
  filter(celltype %in% rownames(annot)) %>%
  mutate(channel = sub("Reporter[.]intensity[.]", "RI", channel)) ->
  idMap
## Add channel info 
annot[idMap$celltype, "Channel"] <- idMap$channel

## Get the peptide data
pep <- readSingleCellExperiment(paste0(dataDir, "Peptides-raw.csv"), 
                                ecol = -c(1,2), fnames = "peptide")
colData(pep) <- annot[colnames(pep), ]
colnames(pep) <- paste0(annot[colnames(pep), "Set"], annot[colnames(pep), "Channel"])
## Include the peptide data in the QFeatures object
specht2019v2 <- addAssay(specht2019v2, pep, name = "peptides")

## Link the PSMs and the peptides
## First find which PSM assays were included
sel <- sapply(grep("19", names(specht2019v2), value = TRUE), function(name) {
  x <- specht2019v2[[name]]
  ## Does the current PSM data have at least 1 colname in common with pep?
  inColnames <- any(colnames(x) %in% colnames(pep))
  ## Does the current PSM data have at least 1 peptide sequence in common with pep?
  inSequence <- any(rowData(x)$peptide %in% rowData(pep)$peptide)
  return(inColnames && inSequence) ## The PSM assay must fulfill both conditions
})
## Add an AssayLink that bridges the PSM assays and the peptide assay
specht2019v2 <- addAssayLink(specht2019v2, from = which(sel), to = "peptides", 
                             varFrom = rep("peptide", sum(sel)), varTo = "peptide")

####---- Include the protein data ----####

## The `Proteins-processed.csv` and `Cells.csv` file was downloaded from 
## https://scope2.slavovlab.net/docs/data 
read.csv(paste0(dataDir, "Proteins-processed.csv")) %>%
  rename(protein = X) %>%
  readSingleCellExperiment(ecol = -1, fnames = "protein") ->
  prot
colData(prot) <- annot[colnames(prot), ]
colnames(prot) <- paste0(annot[colnames(prot), "Set"],
                         annot[colnames(prot), "Channel"])
specht2019v2 <- addAssay(specht2019v2, prot, name = "proteins")
specht2019v2 <- addAssayLink(specht2019v2, from = "peptides", to = "proteins", 
                             varFrom = "protein", varTo = "protein")

## Save data
save(specht2019v2, 
     file = file.path("~/PhD/.localdata/scpdata/specht2019v2.Rda"),
     compress = "xz", 
     compression_level = 9)

