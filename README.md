# Gatk-variantcalling

This repository contains a [Biowdl](https://github.com/biowdl) 
workflows which uses Haplotypecaller to perform variantcalling.

## Documentation

You can find the documentation [here](https://biowdl.github.io/gatk-variantcalling)

## About
This workflow is part of [Biowdl](https://github.com/biowdl),
developed by the SASC team at [Leiden University Medical Center](https://www.lumc.nl/). 

## Usage

```
java -Dconfig.file=docker_slurm.conf -jar /apps/cromwell/cromwell-53.1.jar run multisample-variantcalling.wdl -i tests/integration/single_sample_gvcf.json -o gatk-variantcalling.options.json
```
     
