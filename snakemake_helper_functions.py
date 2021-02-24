def hamming_distance(string1, string2):
    return sum(c1 != c2 for c1, c2 in zip(string1, string2))

def compute_max_barcode_mismatch(indices):
    """computes the maximum number of mismatches allowed for demultiplexing based
    on the indices present in the sample sheet."""
    num_samples = len(indices)
    
    if num_samples == 1:
        return 4
    else:
        max_mismatch = 3
        for i in range(num_samples-1):
            for j in range(i+1, num_samples):
                hd = hamming_distance(indices[i], indices[j])
                max_mismatch = min(max_mismatch, math.ceil(hd/2)-1)
    return max_mismatch

def read_sample_sheet(sample_sheet_path, flowcell_id):
    with open(sample_sheet_path) as sample_sheet:
        ix = 0
        investigator = 'none'
        sequencing_date = 'none'

        for line in sample_sheet:
            line = line.strip('\n')
            if 'Investigator' in line:
                investigator = line.split(',')[1]
            if 'Date' in line:
                sequencing_date = line.split(',')[1]
            if '[Data]' in line:
                break
            else:
                ix = ix + 1

    df = pd.read_csv(sample_sheet_path, skiprows = ix+1)
    df['species'] = df['Description'].str.split('_').str[-1]
    df['investigator'] = investigator
    df['sequencing_date'] = sequencing_date

    # mock R1 and R2
    df['R1'] = 'none'
    df['R2'] = 'none'

    # merge additional info and sanitize column names
    df.rename(columns={"Sample_ID":"sample_id", "Sample_Name":"puck_id", "Sample_Project":"project_id", "Description": "experiment"}, inplace=True)
    df['flowcell_id'] = flowcell_id
    df['demux_barcode_mismatch'] = compute_max_barcode_mismatch(df['index'])
    df['sample_sheet'] = sample_sheet_path
    df['demux_dir'] = df['sample_sheet'].str.split('/').str[-1].str.split('.').str[0]

    # assign the barcode layout for each sample as pecified in the config.yaml
    bcf = config["barcode_flavor"]
    global_default = bcf.get("default", "dropseq")

    def flavor_choice(row):
        project_default = bcf.get(row.project_id, global_default)
        return bcf.get(row.sample_id, project_default)

    df['barcode_flavor'] = df[["project_id", "sample_id"]].apply(flavor_choice, axis=1)

    return df[['sample_id', 'puck_id', 'project_id', 'sample_sheet', 'flowcell_id',
               'species', 'demux_barcode_mismatch', 'demux_dir', 'R1', 'R2', 'barcode_flavor', 'investigator', 'sequencing_date', 'experiment']]    


def get_metadata(field, **kwargs):
    df = project_df
    for key, value in kwargs.items():
        df = df.loc[df.loc[:, key] == value]

    return(df[field].to_list()[0])


def get_demux_indicator(wildcards):
    demux_dir = get_metadata('demux_dir', sample_id = wildcards.sample,
                             project_id = wildcards.project)

    return expand(demux_indicator, demux_dir=demux_dir)

def get_species_info(wildcards):
    # This function will return 3 things required by STAR:
    #    - annotation (.gtf file)
    #    - genome (.fa file)
    #    - index (a directory where the STAR index is)
    species = get_metadata('species', project_id = wildcards.project,
                           sample_id = wildcards.sample)

    return {
        'annotation': config['knowledge']['annotations'][species],
        'genome': config['knowledge']['genomes'][species],
        'index': config['knowledge']['indices'][species]['star']
    }


class dotdict(dict):
    """dot.notation access to dictionary attributes"""
    __getattr__ = dict.get
    __setattr__ = dict.__setitem__
    __delattr__ = dict.__delitem__


bc_defaults = dict(bc1_ref="", bc2_ref="", score_threshold=0.0)
def get_barcode_flavor_info(wildcards, defaults=bc_defaults):
    # This function will return a dictionary of information
    # on the read1 preprocessing, according to barcode_flavor
    print(f"get_barcode_flavor_info {wildcards}")
    flavor = get_metadata('barcode_flavor',
                          project_id=wildcards.project,
                          sample_id=wildcards.sample)

    print(f"wc={wildcards} flavor->{flavor}")
    d = dict(defaults)  # make a copy of the default values    
    d.update(config['knowledge']['barcode_flavor'][flavor])
    return dotdict(d)  # enable d.key access for convenience


def get_rRNA_index(wildcards):
    species = get_metadata('species', project_id = wildcards.project,
                           sample_id = wildcards.sample)

    index = ''

    # return index only if it exists
    if 'bt2_rRNA' in config['knowledge']['indices'][species]:
        index = config['knowledge']['indices'][species]['bt2_rRNA']

    return {
        'rRNA_index': index
    }

def get_dge_extra_params(wildcards):
    dge_type = wildcards.dge_type

    if dge_type == '_exon':
        return ''
    elif dge_type == '_intron':
        return "LOCUS_FUNCTION_LIST=null LOCUS_FUNCTION_LIST=INTRONIC"
    elif dge_type == '_all':
        return "LOCUS_FUNCTION_LIST=INTRONIC"
    if dge_type == 'Reads_exon':
        return "OUTPUT_READS_INSTEAD=true"
    elif dge_type == 'Reads_intron':
        return "OUTPUT_READS_INSTEAD=true LOCUS_FUNCTION_LIST=null LOCUS_FUNCTION_LIST=INTRONIC"
    elif dge_type == 'Reads_all':
        return "OUTPUT_READS_INSTEAD=true LOCUS_FUNCTION_LIST=INTRONIC"

def get_basecalls_dir(wildcards):
    flowcell_id = get_metadata('flowcell_id', demux_dir = wildcards.demux_dir)
    
    basecalls_dir = '/data/remote/basecalls/'
    local_nextseq_raw = '/data/rajewsky/sequencing/nextSeqRaw/'

    # check if flowcell_id exists in local /data/rajewsky/sequencing/nextSeqRaw
    if os.path.isdir(local_nextseq_raw + flowcell_id):
        return [local_nextseq_raw + flowcell_id]
    # if not, check if flowcell_id exists in /data/remote/basecalls
    elif os.path.isdir(basecalls_dir + flowcell_id):
        return [basecalls_dir + flowcell_id]
    # else return a fake path, which won't be present, so snakemake will fail for this, as input directory will be missing
    else:
        return [basecalls_dir + 'none'] 

###############################
# Joining optical to illumina #
###############################

def get_sample_info(raw_folder):
    batches = os.listdir(raw_folder)

    df = pd.DataFrame(columns=['batch_id', 'puck_id'])

    for batch in batches:
        batch_dir = microscopy_raw + '/' + batch

        puck_ids = os.listdir(batch_dir)

        df = df.append(pd.DataFrame({'batch_id': batch, 'puck_id': puck_ids}), ignore_index=True)
        
    return df


###################
# Merging samples #
###################
def get_project(sample):
    # return the project id for a given sample id
    return project_df[project_df.sample_id.eq(sample)].project_id.to_list()[0]

def get_dropseq_final_bam(wildcards):
    # merged_name contains all the samples which should be merged,
    # separated by a dot each
    samples = config['samples_to_merge'][wildcards.merged_project][wildcards.merged_sample]

    input_bams = []

    for sample in samples:
        input_bams = input_bams + expand(dropseq_final_bam,
            project = get_project(sample),
            sample = sample)
    return input_bams

def get_merged_bam_inputs(wildcards):
    # currently not used as we do not tag the bam files with the sample name
    samples = config['samples_to_merge'][wildcards.merged_project][wildcards.merged_sample]

    input_bams = []

    for sample in samples:
        input_bams = input_bams + expand(sample_tagged_bam, 
                merged_sample = wildcards.merged_name,
                sample = sample)

    return input_bams

def get_merged_star_log_inputs(wildcards):
    samples = config['samples_to_merge'][wildcards.merged_project][wildcards.merged_sample]
    
    input_logs = []

    for sample in samples:
        input_logs = input_logs + expand(star_log_file,
                project = get_project(sample),
                sample = sample)

    return input_logs

def get_merged_ribo_depletion_log_inputs(wildcards):
    samples = config['samples_to_merge'][wildcards.merged_project][wildcards.merged_sample]

    ribo_depletion_logs = []

    for sample in samples:
        ribo_depletion_logs = ribo_depletion_logs + expand(ribo_depletion_log, 
                project = get_project(sample),
                sample = sample)

    return ribo_depletion_logs
def get_qc_sheet_parameters(sample_id, umi_cutoff=100):
    # returns a single row for a given sample_id
    # this will be the input of the parameters for the qc sheet parameter generation
    out_dict = projects_puck_info.loc[projects_puck_info.sample_id == sample_id]\
        .iloc[0]\
        .to_dict()

    out_dict['umi_cutoff'] = umi_cutoff
    out_dict['input_beads'] = '60k-100k'

    return out_dict

def get_bt2_index(wildcards):
    species = get_metadata('species', project_id = wildcards.project,
                           sample_id = wildcards.sample)
    
    return config['knowledge']['indices'][species]['bt2']

def get_top_barcodes(wildcards):
    if wildcards.dge_cleaned == '':
        return {'top_barcodes': united_top_barcodes}
    else:
        return {'top_barcodes': united_top_barcodes_clean}

# TODO: need to clean up umi_r2 once barcode_flavor work is done
def get_reverse_first_mate_inputs(wildcards):
    out = {
            'R1': raw_reads_mate_1,
            'R2': raw_reads_mate_2,
            # 'R1_unpacked' : raw_reads_mate_1.replace('fastq.gz', 'fastq'),
            # 'R2_unpacked' : raw_reads_mate_2.replace('fastq.gz', 'fastq'),
        }

    umi_r2 = config['umi_from_r2']

    if wildcards.sample in umi_r2['samples'] or wildcards.project in umi_r2['projects']:
        out['R2'] = raw_reads_mate_2
    # print(f"get_reverse_first_mate_inputs out={out}")
    return (out)
