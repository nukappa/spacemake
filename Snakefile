#########
# about #
#########
__version__ = '0.1.1'
__author__ = ['Nikos Karaiskos', 'Tamas Ryszard Sztanka-Toth']
__license__ = 'GPL'
__email__ = ['nikolaos.karaiskos@mdc-berlin.de', 'tamasryszard.sztanka-toth@mdc-berlin.de']

###########
# imports #
###########
import os
import pandas as pd
import numpy as np
import math

################
# Shell prefix #
################
shell.prefix('set +o pipefail; JAVA_TOOL_OPTIONS="-Xmx8g -Xss2560k" ; umask g+w; ')

#############
# FUNCTIONS #
#############
include: 'snakemake_helper_functions.py'

####
# this file should contain all sample information, sample name etc.
####
# configfile should be loaded from command line

###############
# Global vars #
###############
temp_dir = config['temp_dir']
repo_dir = os.path.dirname(workflow.snakefile)

# set root dir where the processed_data goes
project_dir = config['root_dir'] + '/projects/{project}'
microscopy_root = config['microscopy_root']
microscopy_raw = microscopy_root + '/raw'

illumina_projects = config['illumina_projects']

# get the samples
project_df = pd.concat([read_sample_sheet(ip['sample_sheet'], ip['flowcell_id']) for ip in illumina_projects], ignore_index=True)

# add additional samples from config.yaml, which have already been demultiplexed. add none instead of NaN
project_df = project_df.append(config['additional_illumina_projects'], ignore_index=True).replace(np.nan, 'none', regex=True)
# moved barcode_flavor assignment here so that additional samples/projects are equally processed
project_df = df_assign_bc_flavor(project_df)

# print(project_df)
# print(project_df.columns)
# print(project_df['barcode_flavor'])
# print(get_metadata('R1', sample_id = 'sts_030_4'))
# print(get_metadata('R1', sample_id = 'sts_067_1'))

samples_list = project_df.T.to_dict().values()

# put all projects into projects_puck_info
projects_puck_info = project_df.merge(get_sample_info(microscopy_raw), how='left', on ='puck_id').fillna('none')

projects_puck_info.loc[~projects_puck_info.puck_id.str.startswith('PID_'), 'puck_id']= 'no_puck'

projects_puck_info['type'] = 'normal'

# added samples to merged to the projects_puck_info
# this will be saved as a metadata file in .config/ directory
if 'samples_to_merge' in config:
    for project_id in config['samples_to_merge'].keys():
        for sample_id in config['samples_to_merge'][project_id].keys():
            samples_to_merge = config['samples_to_merge'][project_id][sample_id]

            samples_to_merge = projects_puck_info.loc[projects_puck_info.sample_id.isin(samples_to_merge)]

            new_row = projects_puck_info[(projects_puck_info.project_id == project_id) & (projects_puck_info.sample_id == sample_id)].iloc[0]
            new_row.sample_id = 'merged_' + new_row.sample_id
            new_row.project_id = 'merged_' + new_row.project_id
            new_row.type = 'merged'
            new_row.experiment = ','.join(samples_to_merge.experiment.to_list())
            new_row.investigator = ','.join(samples_to_merge.investigator.to_list())
            new_row.sequencing_date = ','.join(samples_to_merge.sequencing_date.to_list())

            projects_puck_info = projects_puck_info.append(new_row, ignore_index=True)

#################
# DIRECTORY STR #
#################
raw_data_root = project_dir + '/raw_data'
raw_data_illumina = raw_data_root + '/illumina'
raw_data_illumina_reads = raw_data_illumina + '/reads/raw'
raw_data_illumina_reads_reversed = raw_data_illumina + '/reads/reversed'
processed_data_root = project_dir + '/processed_data/{sample}'
processed_data_illumina = processed_data_root + '/illumina'

projects_puck_info_file = config['root_dir'] + '/.config/projects_puck_info.csv'
sample_overview_file = config['root_dir'] + '/.config/sample_overview.html'
sample_read_metrics_db = config['root_dir'] + '/reports/sample_read_metrics_db.tsv'

united_illumina_root = config['root_dir'] + '/projects/{united_project}/processed_data/{united_sample}/illumina'
united_complete_data_root = united_illumina_root + '/complete_data'

##############
# Demux vars #
##############
# Undetermined files pattern
# they are the output of bcl2fastq, and serve as an indicator to see if the demultiplexing has finished
demux_dir_pattern = config['root_dir'] + '/raw_data/demultiplex_data/{demux_dir}'
demux_indicator = demux_dir_pattern + '/indicator.log'

####################################
# FASTQ file linking and reversing #
####################################
reads_suffix = '.fastq.gz'

raw_reads_prefix = raw_data_illumina_reads + '/{sample}_R'
raw_reads_pattern = raw_reads_prefix + '{mate}' + reads_suffix
raw_reads_mate_1 = raw_reads_prefix + '1' + reads_suffix
raw_reads_mate_2 = raw_reads_prefix + '2' + reads_suffix

reverse_reads_prefix = raw_data_illumina_reads_reversed + '/{sample}_reversed_R'
reverse_reads_pattern = reverse_reads_prefix + '{mate}' + reads_suffix
reverse_reads_mate_1 = reverse_reads_prefix + '1' + reads_suffix
reverse_reads_mate_2 = reverse_reads_prefix + '2' + reads_suffix

###############
# Fastqc vars #
###############
bin_dir = config['bin_dir']
fastqc_root = raw_data_illumina + '/fastqc'
fastqc_pattern = fastqc_root + '/{sample}_R{mate}_fastqc.{ext}'
fastqc_command = f'{bin_dir}/FastQC-0.11.2/fastqc'
fastqc_ext = ['zip', 'html']

########################
# UNIQUE PIPELINE VARS #
########################
# set the tool script directories
picard_tools = f'{bin_dir}/picard-tools-2.21.6/picard.jar'
dropseq_tools = f'{bin_dir}/Drop-seq_tools-2.3.0'

# set per sample vars
dropseq_root = processed_data_illumina + '/complete_data'

data_root = dropseq_root
dropseq_reports_dir = dropseq_root + '/reports'
dropseq_tmp_dir = dropseq_root + '/tmp'
smart_adapter = config['adapters']['smart']

# file containing R1 and R2 merged
dropseq_merge_in_mate_1 = reverse_reads_mate_1
dropseq_merge_in_mate_2 = reverse_reads_mate_2
dropseq_merged_reads = dropseq_root + '/unaligned.bam'

###
# splitting the reads
###

united_split_reads_root = united_complete_data_root + '/split_reads/'
united_unmapped_bam = united_split_reads_root + 'unmapped.bam'

united_split_reads_sam_names = ['plus_plus', 'plus_minus', 'minus_minus', 'minus_plus', 'plus_AMB', 'minus_AMB']
united_split_reads_sam_pattern = united_split_reads_root + '{file_name}.sam'
united_split_reads_bam_pattern = united_split_reads_root + '{file_name}.bam'

united_split_reads_sam_files = [united_split_reads_root + x + '.sam' for x in united_split_reads_sam_names]

united_split_reads_strand_type = united_split_reads_root + 'strand_type_num.txt'
united_split_reads_read_type = united_split_reads_root + 'read_type_num.txt'

#######################
# post dropseq and QC #
#######################
# qc generation for ALL samples, merged and non-merged
# umi cutoffs. used by qc-s and automated reports
umi_cutoffs = [10, 50, 100]

#general qc sheet directory pattern
qc_sheet_dir = '/qc_sheet/umi_cutoff_{umi_cutoff}'

# parameters file for not merged samples
qc_sheet_parameters_file = data_root + qc_sheet_dir + '/qc_sheet_parameters.yaml'

united_qc_sheet = united_complete_data_root + qc_sheet_dir + '/qc_sheet_{united_sample}_{puck}.pdf'
united_star_log = united_complete_data_root + '/star_Log.final.out'
united_reads_type_out = united_split_reads_read_type
united_qc_sheet_parameters_file = united_complete_data_root + qc_sheet_dir + '/qc_sheet_parameters.yaml'
united_barcode_readcounts = united_complete_data_root + '/out_readcounts.txt.gz'
united_strand_info = united_split_reads_strand_type

# united final.bam
united_final_bam = united_complete_data_root + '/final.bam'
united_top_barcodes = united_complete_data_root + '/topBarcodes.txt'
united_top_barcodes_clean = united_complete_data_root + '/topBarcodesClean.txt'

# united dge
dge_root = united_complete_data_root + '/dge'
dge_out_prefix = dge_root + '/dge{dge_type}{dge_cleaned}'
dge_out = dge_out_prefix + '.txt.gz'
dge_out_summary = dge_out_prefix + '_summary.txt'
dge_types = ['_exon', '_intron', '_all', 'Reads_exon', 'Reads_intron', 'Reads_all']

dge_all_summary = united_complete_data_root +  '/dge/dge_all_summary.txt'
dge_all_cleaned_summary = united_complete_data_root +  '/dge/dge_all_cleaned_summary.txt'
dge_all_summary_fasta= united_complete_data_root +  '/dge/dge_all_summary.fa'
dge_all = united_complete_data_root +  '/dge/dge_all.txt.gz'
dge_all_cleaned = united_complete_data_root +  '/dge/dge_all_cleaned.txt.gz'

# primer analysis
united_primer_tagged_final_bam = united_complete_data_root +  '/primer_tagged_final.bam'
united_primer_tagged_summary = united_complete_data_root + '/primer_tagged_summary.txt'

# kmer stats per position
kmer_stats_file = data_root + '/kmer_stats/{kmer_len}mer_counts.csv'

# map paired-end to check errors
paired_end_prefix = data_root + '/mapped_paired_end/'
paired_end_sam = paired_end_prefix + '{sample}_paired_end.sam'
paired_end_bam = paired_end_prefix + '{sample}_paired_end.bam'
paired_end_flagstat = paired_end_prefix + '{sample}_paired_end_flagstat.txt'
paired_end_log = paired_end_prefix + '{sample}_paired_end.log'
paired_end_mapping_stats = paired_end_prefix + '{sample}_paired_end_mapping_stats.txt'

# automated analysis
automated_analysis_root = united_complete_data_root + '/automated_analysis/umi_cutoff_{umi_cutoff}'
automated_figures_root = automated_analysis_root + '/figures'
figure_suffix = '{united_sample}_{puck}.png'
automated_figures_suffixes = ['violin_filtered', 'pca_first_components',
    'umap_clusters','umap_top1_markers', 'umap_top2_markers']

automated_figures = [automated_figures_root + '/' + f + '_' + figure_suffix for f in automated_figures_suffixes]
automated_report = automated_analysis_root + '/{united_sample}_{puck}_illumina_automated_report.pdf'
automated_results_metadata = automated_analysis_root + '/{united_sample}_{puck}_illumina_automated_report_metadata.csv'

automated_results_file = automated_analysis_root + '/results.h5ad'

# blast out
blast_db_primers = repo_dir + '/sequences/primers.fa'
blast_db_primers_files = [blast_db_primers + '.' + x for x in ['nhr', 'nin', 'nog', 'nsd', 'nsi', 'nsq']]
blast_header_out = "qseqid sseqid pident length mismatch gapopen qstart qend sstart send sstrand evalue bitscore"
united_barcode_blast_out = united_complete_data_root + '/cell_barcode_primer_blast_out.txt'

# downsample vars
downsample_root = united_illumina_root + '/downsampled_data'

# in silico repo depletion
ribo_depletion_log = data_root + '/ribo_depletion_log.txt'
united_ribo_depletion_log = united_complete_data_root + '/ribo_depletion_log.txt'

# global wildcard constraints
wildcard_constraints:
    sample='(?!merged_).+',
    project='(?!merged_).+',
    dge_cleaned='|_cleaned',
    dge_type = '|'.join(dge_types),
    pacbio_ext = 'fq|fastq'

# #######################
# include dropseq rules #
# #######################
include: 'dropseq.smk'

################################
# Final output file generation #
################################
def get_final_output_files(pattern, projects = None, samples = None, **kwargs):
    samples_to_run = samples_list

    if projects is not None:
        samples_to_run = [s for s in samples_to_run if s['project_id'] in projects]

    if samples is not None:
        samples_to_run = [s for s in samples_to_run if s['sample_id'] in samples]

    out_files = [expand(pattern,
            project=s['project_id'], 
            sample=s['sample_id'],
            puck=s['puck_id'], **kwargs) for s in samples_to_run]

    out_files = [item for sublist in out_files for item in sublist]
    
    return out_files

def get_united_output_files(pattern, projects = None, samples = None,
                            skip_projects = None, skip_samples = None, **kwargs):
    out_files = []
    df = projects_puck_info

    if projects is None and samples is None:
        projects = df.project_id.to_list()
        samples = df.sample_id.to_list()
        #df = df[df.sample_id.isin(samples)]

    df = df[df.sample_id.isin(samples) | df.project_id.isin(projects)]

    if skip_samples is not None:
        df = df[~df.sample_id.isin(skip_samples)]

    if skip_projects is not None:
        df = df[~df.project_id.isin(skip_projects)]

    for index, row in df.iterrows():
        out_files = out_files + expand(pattern,
            united_project = row['project_id'],
            united_sample = row['sample_id'],
            puck=row['puck_id'], 
            **kwargs)

    return out_files

human_mouse_samples = projects_puck_info[projects_puck_info.species.isin(['human', 'mouse'])].sample_id.to_list()

##################
# include pacbio #
##################
processed_data_pacbio = processed_data_root + '/pacbio'
pacbio_fq = raw_data_root + '/pacbio/{sample}.{pacbio_ext}'
pacbio_report = processed_data_pacbio + '/{sample}.report.pdf'
pacbio_stats_file = processed_data_pacbio + '/{sample}.summary.tsv'
pacbio_run_summary = processed_data_pacbio + '/{sample}.examples.txt'
pacbio_rRNA_out = processed_data_pacbio + '/{sample}.rRNA.txt'
pacbio_overview = '/data/rajewsky/projects/slide_seq/.config/pacbio_overview.pdf'
pacbio_overview_csv = '/data/rajewsky/projects/slide_seq/.config/pacbio_overview.csv'
pacbio_bead_overview = '/data/rajewsky/projects/slide_seq/.config/pacbio_bead_overview.pdf'

include: 'pacbio.smk' 

#############
# Main rule #
#############
rule all:
    input:
        get_final_output_files(fastqc_pattern, ext = fastqc_ext, mate = [1,2]),
        get_final_output_files(dropseq_umi_tagged),
        # get_final_output_files(reverse_reads_pattern, mate = [1,2]),
        #get_final_output_files(paired_end_flagstat, samples = ['sts_022', 'sts_030_4', 'sts_025_4', 'sts_032_1_rescued'])
        #get_final_output_files(kmer_stats_file, samples = ['sts_038_1', 'sts_030_4'], kmer_len = [4, 5, 6])
        #get_united_output_files(dge_all_summary),
        # this will also create the clean dge
        get_united_output_files(automated_report, umi_cutoff = umi_cutoffs),
        get_united_output_files(united_qc_sheet, umi_cutoff = umi_cutoffs)
        # get all split bam files
        #get_united_output_files(united_unmapped_bam),
        #get_united_output_files(united_split_reads_bam_pattern, file_name = united_split_reads_sam_names)


########################
# CREATE METADATA FILE #
########################
rule create_projects_puck_info_file:
    output:
        projects_puck_info_file
    run:
        projects_puck_info.to_csv(output[0], index=False)
        os.system('chmod 664 %s' % (output[0]))

rule create_sample_overview:
    input:
        projects_puck_info_file
    output:
        sample_overview_file
    script:
        'create_sample_overview.Rmd'

rule create_sample_db:
    input:
        projects_puck_info_file
    output:
        sample_read_metrics_db
    script:
        'create_sample_db.R'

################
# DOWNSAMPLING #
################
include: 'downsample.smk'

rule downsample:
    input:
        get_united_output_files(downsample_saturation_analysis, projects = config['downsample']['projects'], samples = config['downsample']['samples'])

#################
# MERGE SAMPLES #
#################
include: 'merge_samples.smk'

#########
# RULES #
#########
ruleorder: link_raw_reads > link_demultiplexed_reads 

rule demultiplex_data:
    params:
        demux_barcode_mismatch=lambda wildcards: int(get_metadata('demux_barcode_mismatch', demux_dir = wildcards.demux_dir)),
        sample_sheet=lambda wildcards: get_metadata('sample_sheet', demux_dir = wildcards.demux_dir),
        flowcell_id=lambda wildcards:  get_metadata('flowcell_id', demux_dir = wildcards.demux_dir),
        output_dir= lambda wildcards: expand(demux_dir_pattern, demux_dir=wildcards.demux_dir)
    input:
        unpack(get_basecalls_dir)
    output:
        demux_indicator
    threads: 16
    shell:
        """
        bcl2fastq \
            --no-lane-splitting --fastq-compression-level=9 \
            --mask-short-adapter-reads 15 \
            --barcode-mismatch {params.demux_barcode_mismatch} \
            --output-dir {params.output_dir} \
            --sample-sheet {params.sample_sheet} \
            --runfolder-dir  {input} \
            -p {threads}            

            echo "demux finished: $(date)" > {output}
        """

rule link_demultiplexed_reads:
    input:
        ancient(unpack(get_demux_indicator))
    output:
        raw_reads_pattern
    params:
        demux_dir = lambda wildcards: expand(demux_dir_pattern,
            demux_dir = get_metadata('demux_dir', sample_id = wildcards.sample,
                                     project_id = wildcards.project)),
        reads_folder = raw_data_illumina_reads
    shell:
        """
        mkdir -p {params.reads_folder}

        find {params.demux_dir} -type f -wholename '*/{wildcards.sample}/*R{wildcards.mate}*.fastq.gz' -exec ln -sr {{}} {output} \; 
        """

def get_reads(wildcards):
    return([get_metadata('R'+ wildcards.mate, sample_id = wildcards.sample, project_id = wildcards.project)])

rule link_raw_reads:
    input:
        unpack(get_reads)
    output:
        raw_reads_pattern
    shell:
        """
        ln -s {input} {output}
        """

rule zcat_pipe:
    input: "{name}.fastq.gz"
    output: pipe("{name}.fastq")
    shell: "zcat {input} >> {output}"

rule reverse_first_mate:
    input:
        # these implicitly depend on the raw reads via zcat_pipes
        R1_unpacked = raw_reads_mate_1.replace('fastq.gz', 'fastq'),
        R2_unpacked = raw_reads_mate_2.replace('fastq.gz', 'fastq')
    params:
        bc = lambda wildcards: get_bc_preprocess_settings(wildcards)
    output:
        bam = dropseq_umi_tagged,
        bc_stats = reverse_reads_mate_1.replace(reads_suffix, ".bc_stats.tsv")
    threads: get_bc_preprocessing_threads
    shell:
        "python {repo_dir}/scripts/preprocess_read1.py "
        "--sample={wildcards.sample} "
        "--read1={input.R1_unpacked} "
        "--read2={input.R2_unpacked} "
        "--parallel={threads} "
        "--save-stats={output.bc_stats} "
        "--bc1-ref={params.bc.bc1_ref} "
        "--bc2-ref={params.bc.bc2_ref} "
        "--bc1-cache={params.bc.bc1_cache} "
        "--bc2-cache={params.bc.bc2_cache} "
        "--threshold={params.bc.score_threshold} "
        "--cell='{params.bc.cell}' "
        "--cell-raw='{params.bc.cell_raw}' "
        "--out-format=bam "
        "--UMI='{params.bc.UMI}' "
        "--bam-tags='{params.bc.bam_tags}' "
        "| samtools view -bh /dev/stdin > {output.bam} "

rule reverse_second_mate:
    input:
        raw_reads_mate_2
    output:
        reverse_reads_mate_2
    params:
        reads_folder = raw_data_illumina_reads_reversed
    shell:
        """
        mkdir -p {params.reads_folder}

        ln -sr {input} {output}
        """

rule run_fastqc:
    input:
        # we need to use raw reads here, as later during "reversing" we do the umi
        # extraction, and barcode identification (for the combinatorial barcoding)
        # in order for R1 to have the same pattern
        raw_reads_pattern
    output:
        fastqc_pattern
    params:
        output_dir = fastqc_root 
    threads: 4
    shell:
        """
        mkdir -p {params.output_dir}

        {fastqc_command} -t {threads} -o {params.output_dir} {input}
        """

rule index_bam_file:
    input:
        dropseq_final_bam
    output:
        dropseq_final_bam_ix 
    shell:
       "sambamba index {input}"

rule get_barcode_readcounts:
    # this rule takes the final.bam file (output of the dropseq pipeline) and creates a barcode read count file
    input:
        united_final_bam
    output:
        united_barcode_readcounts
    shell:
        """
        {dropseq_tools}/BamTagHistogram \
        I= {input} \
        O= {output}\
        TAG=XC
        """

rule create_top_barcodes:
    input:
        united_barcode_readcounts
    output:
        united_top_barcodes
    shell:
        "set +o pipefail; zcat {input} | cut -f2 | head -100000 > {output}"

rule clean_top_barcodes:
    input:
        united_top_barcodes
    output:
        united_top_barcodes_clean
    script:
        'scripts/clean_top_barcodes.py'

rule create_dge:
    # creates the dge. depending on if the dge has _cleaned in the end it will require the
    # topBarcodesClean.txt file or just the regular topBarcodes.txt
    input:
        unpack(get_top_barcodes),
        reads=united_final_bam
    output:
        dge=dge_out,
        dge_summary=dge_out_summary
    params:
        dge_root = dge_root,
        dge_extra_params = lambda wildcards: get_dge_extra_params(wildcards)     
    shell:
        """
        mkdir -p {params.dge_root}

        {dropseq_tools}/DigitalExpression \
        -m 16g \
        I= {input.reads}\
        O= {output.dge} \
        SUMMARY= {output.dge_summary} \
        CELL_BC_FILE={input.top_barcodes} \
        CELL_BARCODE_TAG=CB \
        MOLECULAR_BARCODE_TAG=MI \
        TMP_DIR={temp_dir} \
        {params.dge_extra_params}
        """

rule create_qc_parameters:
    params:
        sample_params=lambda wildcards: get_qc_sheet_parameters(wildcards.sample, wildcards.umi_cutoff)
    output:
        qc_sheet_parameters_file
    script:
        "qc_sequencing_create_parameters_from_sample_sheet.py"

rule create_qc_sheet:
    input:
        star_log = united_star_log,
        reads_type_out=united_reads_type_out,
        parameters_file=united_qc_sheet_parameters_file,
        read_counts = united_barcode_readcounts,
        dge_all_summary = dge_all_cleaned_summary,
        strand_info = united_strand_info,
        ribo_log=united_ribo_depletion_log
    output:
        united_qc_sheet
    script:
        "qc_sequencing_create_sheet.py"

rule run_automated_analysis:
    input:
        dge_all_cleaned
    output:
        res_file=automated_results_file
    params:
        fig_root=automated_figures_root
    script:
        'automated_analysis.py'
        
rule create_automated_report:
    input:
        star_log=united_star_log,
        res_file=automated_results_file,
        parameters_file=united_qc_sheet_parameters_file
    output:
        figures=automated_figures,
        report=automated_report,
        results_metadata=automated_results_metadata
    params:
        fig_root=automated_figures_root
    script:
        'automated_analysis_create_report.py'

rule split_final_bam:
    input:
        united_final_bam
    output:
        temp(united_split_reads_sam_files),
        united_split_reads_read_type,
        united_split_reads_strand_type
    params:
        prefix=united_split_reads_root
    shell:
        "sambamba view -F 'mapping_quality==255' -h {input} | python {repo_dir}/scripts/split_reads_by_strand_info.py --prefix {params.prefix} /dev/stdin"

rule split_reads_sam_to_bam:
    input:
        united_split_reads_sam_pattern
    output:
        united_split_reads_bam_pattern
    threads: 2
    shell:
        "sambamba view -S -h -f bam -t {threads} -o {output} {input}"

rule get_unmapped_reads:
    input:
        united_final_bam
    output:
        united_unmapped_bam
    threads: 2
    shell:
        "sambamba view -F 'unmapped' -h -f bam -t {threads} -o {output} {input}"

rule create_dge_barcode_fasta:
    input:
        dge_all_summary
    output:
        dge_all_summary_fasta
    shell:
        """tail -n +8 {input} | awk 'NF==4 && !/^TAG=XC*/{{print ">{wildcards.united_sample}_"$1"_"$2"_"$3"_"$4"\\n"$1}}' > {output}"""

rule create_blast_db:
    input:
        blast_db_primers
    output:
        blast_db_primers_files
    shell:
        "makeblastdb -in {input} -parse_seqids -dbtype nucl"

rule blast_dge_barcodes:
    input:
        blast_db_primers_files,
        db=blast_db_primers,
        barcodes= dge_all_summary_fasta
    output:
        united_barcode_blast_out
    threads: 2
    shell:
        """
        blastn -query {input.barcodes} -evalue 10 -task blastn-short -num_threads {threads} -outfmt "6 {blast_header_out}" -db {input.db} -out {output}"""

rule map_paired_end_bt2:
    input:
        R1 = reverse_reads_mate_1,
        R2 = reverse_reads_mate_2
    output:
        sam=pipe(paired_end_sam),
        logfile=paired_end_log
    threads: 8
    params:
        index= lambda wildcards: get_bt2_index(wildcards)
    shell:
        """
        bowtie2 -x {params.index} \
            -p {threads} \
            -1 {input.R1} \
            -2 {input.R2} \
            --end-to-end --sensitive \
            -S {output.sam} 2>{output.logfile}
        """

rule paired_reads_sam_to_bam:
    input:
        paired_end_sam
    output:
        paired_end_bam
    threads: 8
    shell:
        "sambamba view -S -h -f bam -t {threads} -o {output} {input}"

rule paired_reads_flagstat:
    input:
        paired_end_bam
    threads: 4
    output:
        paired_end_flagstat
    shell:
        "sambamba flagstat -t {threads} {input} > {output}"

rule map_to_rRNA:
    input:
        reverse_reads_mate_2
    output:
        ribo_depletion_log
    params:
        index= lambda wildcards: get_rRNA_index(wildcards)['rRNA_index'] 
    run:
        if wildcards.sample in human_mouse_samples:
            shell("bowtie2 -x {params.index} -U {input} -p 20 --very-fast-local > /dev/null 2> {output}")
        else:
            shell("echo 'no_rRNA_index' > {output}")

rule tag_reads_with_primer_overlap:
    input:
        united_final_bam
    output:
        tagged_bam = united_primer_tagged_final_bam,
        summary = united_primer_tagged_summary
    script:
        'scripts/r1_kmer_analysis.py'

rule calculate_kmer_counts:
    input:
        raw_reads_mate_1
    output:
        kmer_stats_file
    params:
        kmer_len = lambda wildcards: wildcards.kmer_len
    script:
        'scripts/kmer_stats_from_fastq.py'

