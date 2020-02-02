# snakemake root file to create pipeline for the spatial sequencing illumina data
#
# author: tsztank
# email: tamasryszard.sztanka-toth@mdc-berlin.de
#
# ###

####
# import necessary python packages
####
import os
import pandas as pd

####
# get the sample info for each sample_sheet-flowcell_id pair

def get_samples(sample_sheet_path, flowcell_id):
    with open(sample_sheet_path) as sample_sheet:
        ix = 0
        for line in sample_sheet:
            if '[Data]' in line:
                break
            else:
                ix = ix + 1

    df = pd.read_csv(sample_sheet_path, skiprows = ix+1)
    df['species'] = df['Description'].str.split('_').str[1]

    out_dict = {}

    projects = df.Sample_Project.unique()

    for project in projects:
        sample_names = df[df.Sample_Project.eq(project)].Sample_ID.to_list()
        species = df[df.Sample_Project.eq(project)].species.to_list()

        samples = {}
        for i in range(len(sample_names)):
            samples[sample_names[i]] = species[i]

        out_dict[project] = {
            'sample_sheet': sample_sheet_path,
            'flowcell_id': flowcell_id,
            'samples': samples
        }
    
    return out_dict

####
# this file should contain all sample information, sample name etc.
####
configfile: 'config.yaml'

###############
# Global vars #
###############
# set root output dir
project_dir = '{project}'

illumina_projects = config['illumina_projects']

# get the samples
smpls = [get_samples(illumina_project['sample_sheet'], illumina_project['flowcell_id']) for illumina_project in illumina_projects]
samples = {}
for s in smpls:
    samples.update(s)

# create lookup table for flowcell-to-samplesheet
# flowcell_id2samplesheet = {value['flowcell_id'] : value['sample_sheet'] for key, value in samples.items()}

##############
# Demux vars #
##############
# Undetermined files pattern
# they are the output of bcl2fastq, and serve as an indicator to see if the demultiplexing has finished
demux_dir = project_dir + '/demultiplex_data'
demux_indicator = demux_dir + '/indicator.log'

####################################
# FASTQ file linking and reversing #
####################################
reads_suffix = '.fastq.gz'

raw_reads_prefix = project_dir + '/reads/raw/{sample}_R'
raw_reads_pattern = raw_reads_prefix + '{mate}' + reads_suffix
raw_reads_mate_1 = raw_reads_prefix + '1' + reads_suffix
raw_reads_mate_2 = raw_reads_prefix + '2' + reads_suffix

reverse_reads_prefix = project_dir + '/reads/reversed/{sample}_reversed_R'
reverse_reads_pattern = reverse_reads_prefix + '{mate}' + reads_suffix
reverse_reads_mate_1 = reverse_reads_prefix + '1' + reads_suffix
reverse_reads_mate_2 = reverse_reads_prefix + '2' + reads_suffix

###############
# Fastqc vars #
###############
fastqc_root = project_dir + '/reads/fastqc/'
fastqc_pattern = fastqc_root + '{sample}_reversed_R{mate}_fastqc.{ext}'
fastqc_command = '/data/rajewsky/shared_bins/FastQC-0.11.2/fastqc'
fastqc_ext = ['zip', 'html']

#########################
# Dropseq pipeline vars #
#########################
# set the tool script directories
picard_tools = '/data/rajewsky/shared_bins/picard-tools-2.21.6/picard.jar'
dropseq_tools = '/data/rajewsky/shared_bins/Drop-seq_tools-2.3.0'

# set per sample vars
dropseq_root = project_dir + '/data/{sample}'

data_root = dropseq_root
dropseq_reports_dir = dropseq_root + '/reports'
dropseq_tmp_dir = dropseq_root + '/tmp'
smart_adapter = config['adapters']['smart']

# file containing R1 and R2 merged
dropseq_merged_reads = dropseq_root + '/unaligned.bam'

# tag reads with umis and cells
dropseq_cell_tagged = dropseq_root + '/unaligned_tagged_umi_cell.bam'
dropseq_umi_tagged = dropseq_root + '/unaligned_tagged_umi.bam'

# filter out XC tag
dropseq_tagged_filtered = dropseq_root + '/unaligned_tagged_filtered.bam'

# trim smart adapter from the reads
dropseq_tagged_filtered_trimmed = dropseq_root + '/unaligned_tagged_filtered_trimmed.bam'

# trim polyA overheang if exists
dropseq_tagged_filtered_trimmed_polyA = dropseq_root + '/unaligned_tagged_filtered_trimmed_polyA.bam'

# create fastq file from the previous .bam to input into STAR
dropseq_star_input = dropseq_root + '/unaligned_reads_star_input.fastq'

# mapped reads
dropseq_mapped_reads = dropseq_root + '/star_Aligned.out.sam'
star_log_file = dropseq_root + '/star_Log.final.out'

# sort reads and create bam
dropseq_mapped_sorted_reads = dropseq_root + '/star_Aligned.sorted.bam'

# merge bam files
dropseq_merged = dropseq_root + '/merged.bam'

# tag gene with exon
dropseq_gene_tagged = dropseq_root + '/star_gene_tagged.bam'

# detect bead substitution errors
dropseq_bead_substitution_cleaned = dropseq_root + '/clean_substitution.bam'

# detect bead synthesis errors
dropseq_final_bam = dropseq_root + '/final.bam'
synthesis_stats_summary = dropseq_reports_dir + '/detect_bead_synthesis_error.summary.txt'
substitution_error_report = dropseq_reports_dir + '/detect_bead_substitution_error.report.txt'

# index bam file
dropseq_final_bam_ix = dropseq_final_bam + '.bai'

# create readcounts file
dropseq_out_readcounts = dropseq_root + '/out_readcounts.txt.gz'

# create a file with the top barcodes
dropseq_top_barcodes = dropseq_root + '/topBarcodes.txt'

# dges
dge_root = dropseq_root + '/dge'
dge_out_prefix = dge_root + '/dge{dge_type}'
dge_out = dge_out_prefix + '.txt.gz'
dge_out_summary = dge_out_prefix + '_summary.txt'
dge_types = ['_exon', '_intron', '_all', 'Reads_exon', 'Reads_intron', 'Reads_all']

#######################
# post dropseq and QC #
#######################
reads_type_out = dropseq_root + '/uniquely_mapped_reads_type.txt'
cell_number = data_root + '/cell_number.txt'
cell_cummulative_plot = data_root + '/cell_cummulative.png'
downstream_statistics = data_root + '/downstream_statistics.csv'
qc_sheet_parameters_file = data_root + '/qc_sheet/qc_sheet_parameters.yaml'
qc_sheet = data_root + '/qc_sheet/qc_sheet_{sample_id}_{puck_id}.pdf'

################################
# Final output file generation #
################################

print(samples)

def get_final_output_files(pattern, **kwargs):
    out_files = [expand(pattern, project=key, sample=value['samples'], **kwargs) for key, value in samples.items()]

    # flatten the list
    out_files = [item for sublist in out_files for item in sublist]

    return out_files

#############
# Main rule a
#############
rule all:
    input:
        get_final_output_files(fastqc_pattern, ext = fastqc_ext, mate = [1,2])
        #get_final_output_files(dge_out, dge_type = dge_types),
        #get_final_output_files(cell_number),
        #get_final_output_files(dropseq_final_bam_ix),
        #get_final_output_files(qc_sheet)

rule demultiplex_data:
    params:
        samplesheet=lambda wildcards: samples[wildcards.project]['sample_sheet'],
        flowcell_id=lambda wildcards: samples[wildcards.project]['flowcell_id'],
        output_dir= lambda wildcards: expand(demux_dir, project=wildcards.project)
    output:
        demux_indicator
    shell:
        """
        bcl2fastq \
            --no-lane-splitting --fastq-compression-level=9 \
            --mask-short-adapter-reads 15 \
            --barcode-mismatch 1 \
            --output-dir {params.output_dir} \
            --sample-sheet {params.samplesheet} \
            --runfolder-dir /data/remote/basecalls/{params.flowcell_id}

        echo "demux finished: $(date)" > {output}
        """

rule link_raw_reads:
    output:
        raw_reads_pattern
    input:
        demux_indicator
    # isntead of hard links the link is now relative 
    shell:
        """
        mkdir -p {wildcards.project}/reads/raw

        find {wildcards.project}/demultiplex_data -type f -wholename '*/{wildcards.sample}/*R{wildcards.mate}*.fastq.gz' -exec ln -sr {{}} {output} \; 
        """

rule reverse_first_mate:
    input:
        raw_reads_mate_1
    output:
        reverse_reads_mate_1
    params:
        tmp_file_pattern = lambda wildcards: wildcards.project + '/reads/reversed/' + wildcards.sample + '_small'
    script:
        'reverse_fastq_file.py'

rule reverse_second_mate:
    input:
        raw_reads_mate_2
    output:
        reverse_reads_mate_2
    shell:
        """
        mkdir -p {wildcards.project}/reads/reversed

        ln -sr {input} {output}
        """

rule run_fastqc:
    input:
        reverse_reads_pattern
    output:
        fastqc_pattern
    params:
        output_dir = fastqc_root 
    threads: 8
    shell:
        """
        mkdir -p {params.output_dir}

        {fastqc_command} -t {threads} -o {params.output_dir} {input}
        """
# #######################
# include dropseq rules #
# #######################
include: 'dropseq.smk'


rule determine_precentages:
    input:
        dropseq_final_bam
    output:
        reads_type_out
    shell:
        ## Script taken from sequencing_analysis.sh
        """
        samtools view {input} | \
          awk '!/GE:Z:/ && $5 == "255" && match ($0, "XF:Z:") split(substr($0, RSTART+5), a, "\t") {{print a[1]}}' | \
          awk 'BEGIN {{ split("INTRONIC INTERGENIC CODING UTR", keyword)
                      for (i in keyword) count[keyword[i]]=0
                    }}
              /INTRONIC/  {{ count["INTRONIC"]++ }}
              /INTERGENIC/  {{ count["INTERGENIC"]++ }}
              /CODING/ {{count["CODING"]++ }}
              /UTR/ {{ count["UTR"]++ }}
              END   {{
                      for (i in keyword) print keyword[i], count[keyword[i]]
                    }}' > {output}
        """

rule index_bam_file:
    input:
        dropseq_final_bam
    output:
        dropseq_final_bam_ix 
    shell:
       "samtools index {input}"

rule estimate_cell_number:
    input:
        dropseq_out_readcounts = dropseq_out_readcounts
    output:
        cell_number=cell_number,
        cummulative_plot = cell_cummulative_plot
    params:
        knee_limit = 250000
    script:
        "estimate_cell_number.R"

rule create_qc_parameters:
    input:
        samplesheet=lambda wildcards: samples[wildcards.project]['sample_sheet'],
    output:
        qc_sheet_parameters_file
    script:
        "qc_sequencing_create_parameters_from_sample_sheet.py"

def get_dge_input_for_downstream_statistics(wildcards):
    return {
        'dge': expand(dge_out, project=wildcards.project, sample=wildcards.sample, dge_type ='_all'),
        'dgeReads': expand(dge_out, project=wildcards.project, sample=wildcards.sample, dge_type ='Reads_all'),
        'dge_summary': expand(dge_out_summary, project=wildcards.project, sample=wildcards.sample, dge_type ='_all'),
        'dgeReads_summary': expand(dge_out_summary, project=wildcards.project, sample=wildcards.sample, dge_type ='Reads_all')
    }

rule create_downstream_statistics:
    input:
        unpack(get_dge_input_for_downstream_statistics),
        parameters = qc_sheet_parameters_file
    output:
        downstream_statistics 
    script:
        'qc_sequencing_generate_downstream_statistics.R'

rule create_qc_sheet:
    input:
        star_log = star_log_file,
        reads_type_out=reads_type_out,
        synthesis_stats_summary=synthesis_stats_summary,
        substitution_error_report=substitution_error_report,
        parameters_file=qc_sheet_parameters_file,
        read_counts = dropseq_out_readcounts,
        downstream_statistics = downstream_statistics,
        cummulative_plot = cell_cummulative_plot,
    output:
        qc_sheet
    script:
        "qc_sequencing_create_sheet.py"
