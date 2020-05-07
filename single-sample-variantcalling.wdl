version 1.0

# Copyright (c) 2018 Leiden University Medical Center
#
# Permission is hereby granted, free of charge, to any person obtaining a copy
# of this software and associated documentation files (the "Software"), to deal
# in the Software without restriction, including without limitation the rights
# to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
# copies of the Software, and to permit persons to whom the Software is
# furnished to do so, subject to the following conditions:
#
# The above copyright notice and this permission notice shall be included in
# all copies or substantial portions of the Software.
#
# THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
# IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
# FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
# AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
# LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
# OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
# SOFTWARE.

import "tasks/biopet/biopet.wdl" as biopet
import "tasks/gatk.wdl" as gatk
import "tasks/picard.wdl" as picard
import "haplotypecaller.wdl" as haplotype_wf
import "calculate-regions.wdl" as calc
import "tasks/vt.wdl" as vt
import "tasks/samtools.wdl" as samtools

workflow GatkVariantCalling {
    input {
        File bam
        File bamIndex
        String gender = "unknown"
        String outputDir = "."
        String sampleName = basename(bam, ".bam")
        File referenceFasta
        File referenceFastaDict
        File referenceFastaFai
        File? dbsnpVCF
        File? dbsnpVCFIndex
        File? XNonParRegions
        File? YNonParRegions
        Array[File]+ autosomalRegionScatters
        Boolean gvcf = false
        Boolean mergeVcf = true
        Map[String, String] dockerImages = {
          "picard":"quay.io/biocontainers/picard:2.20.5--0",
          "gatk4":"quay.io/biocontainers/gatk4:4.1.0.0--0",
        }
    }
    Boolean male = (gender == "male" || gender == "m" || gender == "M")
    Boolean female = (gender == "female" || gender == "f" || gender == "F")
    Boolean unknownGender = !(male || female)

    Boolean knownParRegions = defined(XNonParRegions) && defined(YNonParRegions)
    Boolean noScatter = length(autosomalRegionScatters) == 1 && !knownParRegions

    String scatterDir = outputDir + "/" + sampleName + "/scatters/"

    scatter (bed in autosomalRegionScatters) {
        String noScatterName = outputDir + "/" + sampleName
        String name = scatterDir + "/" + basename(bed)
        call gatk.HaplotypeCaller as callAutosomal {
            input:
                outputPath = if noScatter then noScatterName else name + if (gvcf) then ".g" else "" + ".vcf.gz",
                intervalList = [bed],
                referenceFasta = referenceFasta,
                referenceFastaIndex = referenceFastaFai,
                referenceFastaDict = referenceFastaDict,
                inputBams = [bam],
                inputBamsIndex = [bamIndex],
                dbsnpVCF = dbsnpVCF,
                dbsnpVCFIndex = dbsnpVCFIndex,
                gvcf = gvcf,
                dockerImage = dockerImages["gatk4"]
        }
    }
    # If the PAR regions are known we call X and Y separately. If not the
    # autosomalRegions BED file will simply have contained all regions.
    if (knownParRegions) {
        # Males have ploidy 1 for X. Call females and unknowns with ploidy 2
        call gatk.HaplotypeCaller as callX {
            input:
                outputPath = if (gvcf) then scatterDir + "/X.g.vcf.gz" else scatterDir + "/X.vcf.gz",
                intervalList = select_all([XNonParRegions]),
                # Females are default.
                ploidy = if male then 1 else 2,
                referenceFasta = referenceFasta,
                referenceFastaIndex = referenceFastaFai,
                referenceFastaDict = referenceFastaDict,
                inputBams = [bam],
                inputBamsIndex = [bamIndex],
                dbsnpVCF = dbsnpVCF,
                dbsnpVCFIndex = dbsnpVCFIndex,
                gvcf = gvcf,
                dockerImage = dockerImages["gatk4"]
        }

        # Only call y on males. Call on unknowns to be sure.
        if (male || unknownGender) {
            call gatk.HaplotypeCaller as callY {
                input:
                    outputPath = if (gvcf) then scatterDir + "/Y.g.vcf.gz" else scatterDir + "/Y.vcf.gz",
                    intervalList = select_all([YNonParRegions]),
                    ploidy = 1,
                    referenceFasta = referenceFasta,
                    referenceFastaIndex = referenceFastaFai,
                    referenceFastaDict = referenceFastaDict,
                    inputBams = [bam],
                    inputBamsIndex = [bamIndex],
                    dbsnpVCF = dbsnpVCF,
                    dbsnpVCFIndex = dbsnpVCFIndex,
                    gvcf = gvcf,
                    dockerImage = dockerImages["gatk4"]
            }
        }
    }

    Array[File] VCFs = flatten([callAutosomal.outputVcfs, select_all([callY.outputVCF, callX.outputVCF])])
    Array[File] VCFIndexes = flatten([callAutosomal.outputVcfsIndex, select_all([callX.outputVCFIndex, callY.outputVCFIndex])])


    if (mergeVcf && !noScatter && gvcf) {
        call gatk.CombineGVCFs as mergeSingleSampleGvcf {
            input:
                gvcfFiles = VCFs,
                gvcfFilesIndex = VCFIndexes,
                outputPath = outputDir + "/" + sampleName + ".g.vcf.gz",
                referenceFasta = referenceFasta,
                referenceFastaFai = referenceFastaFai,
                referenceFastaDict = referenceFastaDict,
                dockerImage = dockerImages["gatk4"]
        }
    }
    if (mergeVcf && !noScatter && !gvcf) {
        call picard.MergeVCFs as mergeSingleSampleVcf {
            input:
                inputVCFs = VCFs,
                inputVCFsIndexes = VCFIndexes,
                outputVcfPath = outputDir + "/" + sampleName + ".vcf.gz",
                dockerImage = dockerImages["picard"]
        }
    }


    output {
        File? outputVcf = if gvcf then mergeSingleSampleGvcf.outputVcf else mergeSingleSampleVcf.outputVcf
        File? outputVcfIndex = if gvcf then mergeSingleSampleGvcf.outputVcfIndex else mergeSingleSampleVcf.outputVcfIndex
        Array[File] VcfScatters = VCFs
        Array[File] VcfIndexScatters = VCFIndexes
    }

    parameter_meta {
        bam: {description: "The bam file", category: "required"}
        bamIndex: {description: "Index of the bam file", category: "required"}
        gender: {description: "Gender of the sample. Accepted values: female,F,f,male,M,m. Other values default to 'unknown'."}
        sampleName: { description: "The basename of the VCF and GVCF files that are outputted by the workflow",
                       category: "common"}
        referenceFasta: { description: "The reference fasta file", category: "required" }
        referenceFastaFai: { description: "Fasta index (.fai) file of the reference", category: "required" }
        referenceFastaDict: { description: "Sequence dictionary (.dict) file of the reference", category: "required" }
        dbsnpVCF: { description: "dbsnp VCF file used for checking known sites", category: "common"}
        dbsnpVCFIndex: { description: "Index (.tbi) file for the dbsnp VCF", category: "common"}
        outputDir: { description: "The directory where the output files should be located", category: "common" }
        autosomalRegionScatters: {description: "A list of BED files describing the regions to operate on.", category: "common"}
        XNonParRegions: {description: "Bed file with the non-PAR regions of X", category: "common"}
        YNonParRegions: {description: "Bed file with the non-PAR regions of Y", category: "common"}
        dockerImages: { description: "specify which docker images should be used for running this pipeline",
                        category: "advanced" }
        gvcf: {description: "Whether to call in GVCF mode.",
                          category: "common"}
        singleSampleGvcf: {description: "Whether to output single-sample gvcfs", category: "common"}
    }
}