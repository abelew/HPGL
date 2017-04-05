package CYOA;

## LICENSE: gplv2
## ABSTRACT:  Kitty!
use autodie qw":all";
use Modern::Perl;
use diagnostics;
use warnings qw"all";
use AppConfig qw":argcount :expand";
use Archive::Extract;
##use Bio::DB::Sam;
use Bio::SeqIO;
use Bio::DB::Universal;
use Bio::Root::RootI;
use Bio::SeqIO;
use Bio::Tools::GFF;
use Cwd qw"cwd";
use Data::Dumper;
use Digest::MD5 qw"md5 md5_hex md5_base64";
use File::Basename;
use File::Find;
use File::Spec;
use File::Which qw"which";
use File::Path qw"make_path remove_tree";
use FileHandle;
use Getopt::Long qw"GetOptionsFromArray";
use IO::String;
##use Log::Log4perl;
##use Log::Log4perl::Level;
##use Net::Amazon::S3;
use PerlIO;
use Pod::Usage;
use Storable qw"freeze thaw store retrieve";
use Term::ReadLine;
use Term::UI;

use CYOA::Align;
use CYOA::Align_Blast;
use CYOA::Align_Fasta;
use CYOA::Cleanup;
use CYOA::Compress;
use CYOA::Convert;
use CYOA::PBS;
use CYOA::Prepare;
use CYOA::RNASeq_QA;
use CYOA::RNASeq_Trim;
use CYOA::RNASeq_Aligners;
use CYOA::RNASeq_Count;
use CYOA::SeqMisc;
use CYOA::SNP;
use CYOA::TNSeq;

our $AUTOLOAD;
require Exporter;
our @ISA = qw"Exporter";
our @EXPORT = qw"";
use vars qw"$VERSION";
$VERSION = '20151101';
$ENV{COMPRESSION} = 'xz';
$ENV{XZ_OPTS} = '-9e';
$ENV{XZ_DEFAULTS} = '-9e';
$ENV{GZIP} = '--best';

=head1 NAME

    CYOA - A perl library to make preprocessing high-throughput data easier.

=head1 SYNOPSIS

    CYOA.pm CYOA::Job.pm Some perl libraries to submit jobs to the
    umiacs cluster.  This can take a variety of options:

  --debug|d   : Get it to print some debugging information.
  --btmulti   : Perform multiple bowtie option sets.
  --tpmulti   : Perform multiple tophat option sets (not implemented).
  --bwmulti   : Perform multiple bwa option sets (not implemented).
  --help      : Print some help information.
  --input|i   : Input file(s).
  --pbs|p     : Use Torque?
  --species:s : Species used for alignments.
  --stranded  : Are the libraries stranded?
  --identifier: The identifier tag in the annotation gff

    use CYOA;
    my $hpgl = new CYOA;
    $hpgl->{species} = 'mmusculus';  ## There had better be a mmusculus.[fasta&gff] in $hpgl->{libdir}
    my $hpgl = new CYOA(species => 'scerevisiae', libdir => '/home/bob/libraries');
    $hpgl->{input} = 'test.fastq';  ## Also via with script.pl --input=test.fastq

    ## Run Fastqc on untrimmed sequence.
    my $bp = $hpgl->Fastqc()
    ## Generates test-trimmed.fastq from test.fastq
    my $trim = $hpgl->Trimomatic();
    ## Graph statistics from test-trimmed.fastq
    my $bp = $hpgl->Biopieces_Graph(depends => $trim->{pbs_id});
    ## Run bowtie1, convert the output to sorted/indexed bam, and run htseq-count against mmusculus
    ## bowtie1 outputs go (by default) into bowtie_out/
    my $bt = $hpgl->Bowtie();
    ## Run htseq-count with a different gff file, use 'mRNA' as the 3rd column of the gff, and 'locus_tag' as the identifier in the last column.
    my $ht = $hpgl->HTSeq(depends => $bt->{pbs_id}, input => $bt->{output}, htseq_gff => 'other.gff', htseq_type => 'mRNA', htseq_identifier => 'locus_tag'
    ## Run tophat
    my $tp = $hpgl->TopHat(depends => $trim->{pbs_id});
    ## or BWA
    my $bw = $hpgl->BWA(depends => $trim->{pbs_id});

=head1 DESCRIPTION

    This library should write out PBS compatible job files for torque and
    submit them to appropriate queues on the cluster.  It should also
    collect the outputs and clean up the mess.

=head2 Methods

=over 4

=item C<new>

    new() instantiates a new CYOA object.
    It has a plethora of options which are either pulled from
    GetOpt::Long or via a hash of default values.

    Each tool used herein therefore has access to all of these variables as
    a part of the instance created.

    For example, one might do:
    my $hp = new CYOA;
    print "$hp->{libtype};"
    and see that the default library is 'genome' (as opposed to rRNA).

    Each function in CYOA also gathers parameters as a hash from the parameter list.

    One point of potential confusion is the hash reference: $me->{methods} = { ... };
    Each of the keys of that hash are plus suffixed names for functions available
    in CYOA.  The values are references to the originally empty hash $me->{todo}.
    In cyoa, GetOpt::Long is used to parse the command line arguments and if any
    arguments approximately match any of those keys, then the corresponding element in
    $todo is incremented from 0 to 1.  Therefore, for every switch provided the corresponding
    function will be called.

=cut
sub new {
    my ($class, %args) = @_;
    my $me = bless {}, $class;
    foreach my $key (keys %args) {
        $me->{$key} = $args{$key} if (defined($args{$key}));
    }
    $me->{appconfig} = new AppConfig({
        CASE => 1,
        CREATE => 1,
        PEDANTIC => 0,
        ## ERROR => eval(),
        GLOBAL => {
            EXPAND => EXPAND_ALL,
            EXPAND_ENV => 1,
            EXPAND_UID => 1,
            DEFAULT => 'unset',
            ARGCOUNT => 1,
        },});

    ## Set up the readline interface.
    my $term = new Term::ReadLine('>');
    my $attribs = $term->Attribs;
    ##$attribs->{CompleteAddsuffix} = 0;
    $attribs->{completion_suppress_append} = 1;
    my $OUT = $term->OUT || \*STDOUT;
    $Term::UI::VERBOSE = 0;
    ### always pick the default (good for non-interactive terms)
    ### -- default is '0'
    ##$Term::UI::AUTOREPLY = 1;
    $term->ornaments(0);
    $me->{term} = $term;

    ## First fill out a set of default configuration values
    ## The following for loop will include all of these in conf_specification_temp
    ## which will in turn be passed to GetOpts
    ## As a result, _all_ of these variables may be overridden on the command line.
    ## Default shell to use for shell commands (especially PBS)
    $me->{shell} = '/usr/bin/bash' if (!defined($me->{shell}));
    ## Perform alignments of trimmed sequence?
    $me->{align_trimmed} = 1 if (!defined($me->{align_trimmed}));
    ## Parse blast/fasta alignments after finishing them?
    $me->{align_parse} = 1 if (!defined($me->{align_parse}));
    ## Use this aligner if none is chosen
    $me->{aligner} = 'bowtie' if (!defined($me->{aligner}));
    ## How many alignment jobs should we make?
    $me->{align_jobs} = 40 if (!defined($me->{align_jobs}));
    ## Which alignment type should we use?  (5 is blastxml for blast, 0 is tabular for fasta36)
    $me->{align_outtype} = 0 if (!defined($me->{align_outtype}));
    ## Return only the best alignments for blast/fasta
    $me->{align_bestonly} = 0 if (!defined($me->{aligne_bestonly}));
    ## This isn't actually user-configurable, I should move it, but it is used to count the number of sequences to be aligned by fasta/blast
    $me->{align_numseq} = 0 if (!defined($me->{align_numseq}));
    ## Used for mimapping for now, but should also be used for tnseq/riboseq/etc
    $me->{bamfile} = undef;
    ## The range of bam sizes considered as 'small' read lengths (ribosome profiling)
    $me->{bam_small} = '21-26' if (!defined($me->{bam_small}));
    ## The range of bam sizes considered as 'medium' read lengths (ribosome profiling)
    $me->{bam_mid} = '27-32' if (!defined($me->{bam_mid}));
    ## The range of bam sizes considered as 'large' read lengths (ribosome profiling)
    $me->{bam_big} = '33-40' if (!defined($me->{bam_big}));
    ## The base directory when invoking various shell commands
    $me->{basedir} = cwd() if (!defined($me->{basedir}));
    ## A couple default blast parameters
    $me->{blast_params} = ' -e 10 ' if (!defined($me->{blast_params}));
    ## Valid choices are blastn blastp tblastn tblastx and I'm sure some others I can't remember
    $me->{blast_tool} = undef;
    ## The flag for blast deciding whether or not to perform a peptide formatdb/alignment
    $me->{blast_peptide} = 'F' if (!defined($me->{blast_peptide}));
    ## A series of default bowtie1 arguments
    $me->{bt_args} = {
        def => ' ',
        v0M1 => ' --best -v 0 -M 1 ',
        ## v1M1 => ' --best -v 1 -M 1 ',
        ##v1M1l10 => ' --best -v 1 -M 1 -y -l 15 ',
        ##v2M1 => ' --best -v 2 -M 1 ',
    } if (!defined($me->{bt_args}));
    $me->{bt2_args} = ' --very-sensitive ' if (!defined($me->{bt2_args}));
    ## A boolean to decide whether to use multiple bowtie1 argument sets
    $me->{btmulti} = 0 if (!defined($me->{btmulti}));
    ## Use the following configuration file to overwrite options for these scripts
    $ENV{CEPH_HOST} = 'undefined' if (!defined($ENV{CEPH_HOST}));
    $me->{ceph_host} = qq"$ENV{CEPH_HOST}" if (!defined($me->{ceph_host}));
    $ENV{CEPH_ID} = 'undefined' if (!defined($ENV{CEPH_ID}));
    $me->{ceph_id} = qq"$ENV{CEPH_ID}" if (!defined($me->{ceph_id}));
    $ENV{CEPH_KEY} = 'undefined' if (!defined($ENV{CEPH_KEY}));
    $me->{ceph_key} = qq"$ENV{CEPH_KEY}" if (!defined($me->{ceph_key}));
    $me->{check_path} = 0 if (!defined($me->{check_path}));
    $me->{cpus} = 1 if (!defined($me->{cpus}));
    $me->{config_file} = qq"$ENV{HOME}/.config/hpgl.conf" if (!defined($me->{config_file}));
    ## Debugging?
    $me->{csv_file} = 'all_samples.csv' if (!defined($me->{csv_file}));
    $me->{debug} = 0 if (!defined($me->{debug}));
    ## A flag for PBS telling what each job depends upon
    $me->{depends} = undef;
    $me->{fasta_args} = ' -b 20 -d 20 ' if (!defined($me->{fasta_args}));
    $me->{fasta_tool} = 'ggsearch36' if (!defined($me->{fasta_tool}));
    ## A default feature type when examining gff files
    $me->{feature_type} = 'CDS' if (!defined($me->{feature_type}));
    ## A default gff file!
    $me->{genome} = undef;
    $me->{gff} = undef;
    ## Ask for help?
    $me->{help} = undef;
    ## An hpgl identifier
    $me->{hpgl} = undef;
    ## The identifier flag passed to htseq (probably should be moved to feature_type)
    $me->{htseq_args} = {
        hsapiens => " ",
        mmusculus => " -i ID ",
        lmajor => " -i ID ",
        default => " --order=name --idattr=gene_id --minaqual=10 --type=exon --stranded=yes --mode=union ",
        ## all => " -i ID ",
        all => " ",
    } if (!defined($me->{htseq_args}));
    ## Use htseq stranded options?
    $me->{htseq_stranded} = 'no' if (!defined($me->{htseq_stranded}));
    ## An index file for tnseq (change this variable to tnseq_index I think)
    $me->{htseq_type} = undef;
    $me->{index_file} = 'indexes.txt' if (!defined($me->{index_file}));
    ## The default input file
    $me->{input} = undef;
    ## A list of jobs
    $me->{jobs} = [] if (!defined($me->{jobs}));
    ## And a hash of jobids
    $me->{jobids} = {} if (!defined($me->{jobids}));
    ## Minimum length for good reads (riboseq): FIXME rename this
    $me->{job_name} = undef;
    $me->{job_string} = undef;
    $me->{len_min} = 16 if (!defined($me->{len_min}));
    ## Maximum length for good reads (riboseq): FIXME rename this
    $me->{len_max} = 42 if (!defined($me->{len_max}));
    ## The default directory for gff/fasta/genbank/indexes
    $me->{library} = undef;
    $me->{libdir} = "$ENV{HOME}/libraries" if (!defined($me->{libdir}));
    ## What type of library are we going to search for?
    $me->{libtype} = 'genome' if (!defined($me->{libtype}));
    $me->{method} = undef;
    ## Currently only used for snp calling, but name is probably a useful arg for many things.
    $me->{name} = undef;
    ## What is the orientation of the read with respect to start/stop codon (riboseq) FIXME: Rename this
    $me->{orientation} = 'start' if (!defined($me->{orientation}));
    ## Paired reads?
    $me->{output} = undef;
    $me->{paired} = 0 if (!defined($me->{paired}));
    ## Use pbs?
    $me->{pbs} = undef;
    ## What arguments will be passed to qsub by default?
    $me->{qsub_args} = '-j oe -V -m n' if (!defined($me->{qsub_args}));
    ## What queue will jobs default to?
    $me->{qsub_queue} = 'workstation' if (!defined($me->{qsub_queue}));
    ## Other possible queues
    $me->{qsub_queues} = ['throughput','workstation','long','large'] if (!defined($me->{qsub_queues}));
    $me->{qsub_shell} = '/usr/bin/bash' if (!defined($me->{qsub_shell}));
    $me->{qsub_mem} = 6 if (!defined($me->{qsub_mem}));
    $me->{qsub_wall} = '10:00:00' if (!defined($me->{qsub_wall}));
    $me->{qsub_cpus} = '4' if (!defined($me->{qsub_cpus}));
    $me->{qsub_depends} = 'depend=afterok:' if (!defined($me->{qsub_depends}));
    $me->{qsub_dependsarray} = 'depend=afterokarray:' if (!defined($me->{qsub_dependsarray}));
    $me->{qsub_loghost} = 'localhost' if (!defined($me->{qsub_loghost}));
    $me->{qual} = undef;
    $me->{query} = undef;
    $me->{raw_dir} = undef;
    $me->{riboasite} = 1 if (!defined($me->{riboasite}));
    $me->{ribopsite} = 1 if (!defined($me->{ribopsite}));
    $me->{riboesite} = 1 if (!defined($me->{riboesite}));
    $me->{ribominsize} = 24 if (!defined($me->{ribominsize}));
    $me->{ribomaxsize} = 36 if (!defined($me->{ribomaxsize}));
    $me->{ribominpos} = -30 if (!defined($me->{ribominpos}));
    $me->{ribomaxpos} = 30 if (!defined($me->{ribomaxpos}));
    $me->{ribocorrect} = 1 if (!defined($me->{ribocorrect}));
    $me->{riboanchor} = 'start' if (!defined($me->{rioanchor}));
    $me->{ribosizes} = '25,26,27,28,29,30,31,32,33,34' if (!defined($me->{ribosizes}));
    $me->{species} = undef;
    $me->{suffixes} = ['.fastq', '.gz', '.xz', '.fasta', '.sam', '.bam', '.count', '.csfasta', '.qual'] if (!defined($me->{suffixes}));
    $me->{task} = undef;
    $me->{taxid} = '353153' if (!defined($me->{taxid}));
    $me->{tnseq_trim} = 0 if (!defined($me->{tnseq_trim}));
    $me->{trimmer} = 'trimmomatic' if (!defined($me->{trimmer}));
    $me->{type} = undef;
    $me->{verbose} = 0 if (!defined($me->{verbose}));

    ## These are used for mature miRNA mapping
    $me->{mi_genome} = undef;
    $me->{mature_fasta} = undef;
    $me->{mirbase_data} = undef;
    ## End of miRNA mapping options

    ## Some variables depend on others, put them here.
    $me->{qsub_logdir} = qq"$me->{basedir}/outputs/qsub" if (!defined($me->{qsub_logdir}));
    my $blast_species = $me->{species};
    $blast_species = 'lmajor' if (!defined($blast_species));
    $me->{blast_format} = "formatdb -p $me->{blast_peptide} -o T -n blastdb/${blast_species} -s -i" if (!defined($me->{blast_format}));

    ## Now that the set of defaults has been created, allow it to be changed via a config file
    ## All the stuff above may therefore be overwritten by entries in the config file.
    ## which defaults to ~/.config/hpgl.conf
    my ($open, %data, $config_option);
    if (-r $me->{config_file}) {
        $open = $me->{appconfig}->file($me->{config_file});
        %data = $me->{appconfig}->varlist("^.*");
        for $config_option (keys %data) {
            $me->{$config_option} = $data{$config_option};
            undef $data{$config_option};
        }
    }

    ## Options set in the config file are trumped by those placed on the comamnd line.
    my (%conf, %conf_specification, %conf_specification_temp);
    foreach my $default (keys %{$me}) {
        $conf_specification{"$default:s"} = \$conf{$default};
    }
    ## For some command line options, one might want shortcuts etc, set those here:
    %conf_specification_temp = (
        "de|d" => \$conf{debug},
        "hp|h:s" => \$conf{hpgl},
        "in|i:s" => \$conf{input},
        "pb|p:i" => \$conf{pbs},
        "sp|s:s" => \$conf{species},
        );
    ## This makes both of the above groups command-line changeable
    foreach my $name (keys %conf_specification_temp) {
        $conf_specification{$name} = $conf_specification_temp{$name};
    }
    undef(%conf_specification_temp);
    ## Now pull out the command line options.
    my $argv_result = GetOptions(%conf_specification);
    ##unless ($argv_result) {
    ##    Help();
    ##}

    ## Finally merge the options from the config file to those
    ## in the default hash and those from the command line.
    foreach my $opt (keys %conf) {
        if (defined($conf{$opt})) {
            $me->{$opt} = $conf{$opt};
        }
    }
    undef(%conf);
    Help() if (defined($me->{help}));

    my @suffixes = @{$me->{suffixes}};
    if ($me->{input}) {
        my $base = $me->{input};
        if ($base =~ /:|\,/) {
            my @tmp = split(/:|\,/, $base);
            $base = $tmp[0];
            $base =~ s/_forward//g;
            $base =~ s/_R1//g;
        }
        $base = basename($base, @suffixes);
        $base = basename($base, @suffixes);
        $me->{basename} = $base;
        if (!defined($me->{hpglid})) {
            my $tmp = $me->{input};
            $tmp =~ s/^(hpgl\d+).*/$1/g;
            $me->{hpglid} = $tmp;
        }
    } else {
        my $base = basename($me->{basedir}, @suffixes);
        $me->{basename} = $base;
    }

    my $qsub_path = which 'qsub';
    if ($qsub_path) {
        $me->{pbs} = 1;
    } else {
        $me->{pbs} = 0;
    }

    my %needed_programs = ('trimomatic' => 'http://www.usadellab.org/cms/?page=trimmomatic',
                           'cutadapt' => 'https://pypi.python.org/pypi/cutadapt/',
                           'bowtie' => 'http://bowtie-bio.sourceforge.net/index.shtml',
                           'bowtie2' => 'http://bowtie-bio.sourceforge.net/bowtie2/index.shtml',
                           'tophat' => 'https://ccb.jhu.edu/software/tophat/index.shtml',
                           'fastqc' => 'http://www.bioinformatics.babraham.ac.uk/projects/fastqc/',
                           'bwa' => 'http://bio-bwa.sourceforge.net/',
                           'xz' => 'http://tukaani.org/xz/',
                           'htseq-count' => 'http://www-huber.embl.de/users/anders/HTSeq/doc/count.html',
                           'plot_scores' => 'https://github.com/maasha/biopieces',
                           'samtools' => 'http://samtools.sourceforge.net/',
        );
    my $failed = 0;
    if ($me->{check_path}) {
        foreach my $prog (keys %needed_programs) {
            my $url = $needed_programs{$prog};
            my $found = which($prog);
            if (!$found) {
                $failed++;
                warn("CYOA.pm requires $prog, which may be found at: ${url}");
            }
        }
        if ($failed) {
            warn("CYOA.pm requires external programs, of which $failed were missing.");
        }
    }
    $me->{todo} = ();
    $me->{methods} = {
        "arbitrary+" => \$me->{todo}{Qsub_Arbitrary},
        "biopieces+" => \$me->{todo}{Biopieces_Graph},
        "blastparse+" => \$me->{todo}{Blast_Parse},
        "blastsplitalign+" => \$me->{todo}{Split_Align_Blast},
        "bowtierrna+" => \$me->{todo}{Bowtie_RRNA},
        "bt2+" => \$me->{todo}{Bowtie2},
        "btmulti+" => \$me->{todo}{BT_Multi},
        "calibrate+" => \$me->{todo}{Calibrate},
        "copyraw+" => \$me->{todo}{Copy_Raw},
        "countstates+" => \$me->{todo}{Count_States},
        "concat+" => \$me->{todo}{Concatenate_Searches},
        "cutadapt+" => \$me->{todo}{Cutadapt},
        "downceph+" => \$me->{todo}{Ceph_Download},
        "dumpceph+" => \$me->{todo}{Ceph_Dump},
        "essentialitytas+" => \$me->{todo}{Essentiality_TAs},
        "splitalignfasta+" => \$me->{todo}{Split_Align_Fasta},
        "fastasplitalign+" => \$me->{todo}{Split_Align_Fasta},
        "fastaparse+" => \$me->{todo}{Parse_Fasta},
        "fastqc+" => \$me->{todo}{Fastqc},
        "gb2gff+" => \$me->{todo}{Gb2Gff},
        "gff2fasta+" => \$me->{todo}{Gff2Fasta},
        "graphreads+" => \$me->{todo}{Graph_Reads},
        "htmulti+" => \$me->{todo}{HT_Multi},
        "htseq+" => \$me->{todo}{HTSeq},
        "indexbt1+" => \$me->{todo}{BT1_Index},
        "indexbt2+" => \$me->{todo}{BT2_Index},
        "indexbwa+" => \$me->{todo}{BWA_Index},
        "indexkallisto+" => \$me->{todo}{Kallisto_Index},
        "kallisto+" => \$me->{todo}{Kallisto},
        "mergeparse+" => \$me->{todo}{Merge_Parse_Blast},
        "mimap+" => \$me->{todo}{Mi_Map},
        "pbt1+" => \$me->{todo}{RNAseq_Pipeline_Bowtie},
        "pbt2+" => \$me->{todo}{RNAseq_Pipeline_Bowtie2},
        "pbwa+" => \$me->{todo}{RNAseq_Pipeline_BWA},
        "pkallisto+" => \$me->{todo}{RNAseq_Pipeline_Kallisto},
        "ptophat+" => \$me->{todo}{RNAseq_Pipeline_Tophat},
        "ptnseq+" => \$me->{todo}{TNseq_Pipeline},
        "priboseq+" => \$me->{todo}{Riboseq_Pipeline},
        "parseblast+" => \$me->{todo}{Parse_Blast},
        "posttrinity+" => \$me->{todo}{Trinity_Post},
        "runessentiality+" => \$me->{todo}{Run_Essentiality},
        "sam2bam+" => \$me->{todo}{Sam2Bam},
        "snpsearch+" => \$me->{todo}{SNP_Search},
        "snpratio+" => \$me->{todo}{SNP_Ratio},
        "sortindexes+" => \$me->{todo}{Sort_Indexes},
        "splitalign+" => \$me->{todo}{Split_Align},
        "tacheck+" => \$me->{todo}{TA_Check},
        "test+" => \$me->{todo}{Test_Job},
        "tophat+" => \$me->{todo}{Tophat},
        "trimomatic+" => \$me->{todo}{Trimomatic},
        "trinity+" => \$me->{todo}{Trinity},
        "tritrypdownload+" => \$me->{todo}{TriTryp_Download},
        "tritryp2text+" => \$me->{todo}{TriTryp2Text},
        "uploadceph+" => \$me->{todo}{Ceph_Upload},
        "helpme+" => \$me->{todo}{CYOA_Help},
    };
    $me->{menus} = {
        Prepare => {
            name => 'preparation',
            message => "Whan that Aprille withe her shoures sote, the droughte of Marche hath perced to the rote.  go to Cantebury.",
            choices => ['Read_Samples', 'Copy_Raw','Dump_Reads','Ceph_Upload',],},
        RNASeq => {
            name => 'rnaseq',
            message => "The world is dark and full of terrors, take this and go to page 6022140.",
            choices => ['Fastqc','Biopieces_Graph','Trimomatic','Bowtie', 'Bowtie2', 'BT_Multi','Bowtie_RRNA',
                        'BWA','Kallisto','Tophat','Sam2Bam','HT_Multi','Trinity','Trinity_Post',
                        'BT1_Index', 'BT2_Index', 'BWA_Index', 'Kallisto_Index', 'SNP_Search',
                        'Mi_Map'],},
        TNSeq => {
            name => 'tnseq',
            message => "You have enterred a world of jumping DNA, be ware and go to page 42.",
            choices => ['Sort_Indexes','Biopieces_Graph','Cutadapt','BT_Multi','Essentiality_TAs',
                        'TA_Check', 'Run_Essentiality',],},
        RiboSeq => {
            name => 'riboseq',
            message => "Awake Awake Fear Fire Foes!  Go to page 5291772",
            choices => ['Biopieces_Graph','Cutadapt','BT_Multi','Calibrate','Count_States','Graph_Reads',],},
        Alignment => {
            name => 'alignment',
            message => "Hari Seldon once said violence is the last refuge of the incompetent.  Go to page 6626070.",
            choices => ['Split_Align_Blast','Split_Align_Fasta','Concatenate_Searches','Parse_Fasta','Parse_Blast','Merge_Parse_Blast'],},
        Conversion => {
            name => 'convert',
            message => qq"And it rained a fever. And it rained a silence. And it rained a sacrifice. And it rained a miracle. And it rained sorceries and saturnine eyes of the totem.  Go to page 2584981.",
            choices => ['Sam2Bam','Gb2Gff','Gff2Fasta', 'TriTryp2Text','TriTryp_Download',],},
        Counting => {
            name => 'count',
            message => qq"Once men turned their thinking over to machines in the hope that this would set them free. But that only permitted other men with machines to enslave them.  Go to page 27812",
            choices => ['HTSeq', 'HT_Multi', 'Mi_Map', 'Count_States'], },
        Assembly => {
            name => 'assembly',
            message => qq"The wise man fears the wrath of a gentle heart. Go to page 314159.",
            choices => ['Trinity', 'Trinity_Post',]},
        Pipeline => {
            name => 'pipeline',
            message => qq"When Mr. Bilbo Baggins announced he would shortly be celebrating his eleventyfirst birthday, there was much talk and excitement in Hobbiton.  Go to page 1618033",
            choices => ['Pipeline_Riboseq','Pipeline_TNseq','Pipline_RNAseq_Bowtie','Pipline_RNAseq_Bowtie2','Pipline_RNAseq_Tophat','Pipline_RNAseq_BWA','Pipline_RNAseq_Kallisto',]},
        SNP => {
            name => 'snp',
            message => qq"When my god comes back I'll be waiting for him with a shotgun.  And I'm keeping the last shell for myself. (inexact quote)  Go to page 667408",
            choices => ['SNP_Search','SNP_Ratio'], },
        Test => {
            name => 'test',
            message => qq"All happy families are happy in the same way. Go to page 5670367.",
            choices => ['Test_Job',],},
    };
    return($me);
}

=item C<Help>

    Help() always gives 0.
    Before it returns, it will hopefully print some useful information
    regarding ways to invoke CYOA.pm.

=cut
sub Help {
    my $me = shift;
    my $fh = \*STDERR;
    ##    my $usage = pod2usage(-output => $fh, -verbose => 99, -sections => "SYNOPSIS");
    use Pod::Find qw(pod_where);
    pod2usage(-input => pod_where({-inc => 1}, __PACKAGE__), -verbose => 2, -output => $fh, -sections => "NAME|SYNOPSIS|DESCRIPTION|VERSION", -exitval => 'NOEXIT');
    ##my $usage = pod2usage(-verbose => 2, -output => $fh, -sections => "NAME|SYNOPSIS|DESCRIPTION|VERSION", -exitval => 'NOEXIT');
    ##print STDERR "Ran pod2usage\n";
    ##print Dumper $usage;
    return(0);
}

=item C<Check_Options>

    Check_Options() currently does not return anything, but instead
    will check to see if specific required options were given to
    CYOA.pm, if they are not defined, it will open an interactive
    terminal and query the user for the requisite information.

=cut
sub Check_Options {
    my $me = shift;
    my %args = @_;
    my $argref = {};
    if (defined($args{args})) {
        $argref = $args{args};
    }
    my $needed_list = [];
    if (defined($args{needed})) {
        $needed_list = $args{needed};
    }
    my @options = @{$needed_list};
    foreach my $option (@options) {
        if (defined($argref->{$option})) {
            $me->{$option} = $argref->{$option};
        }
        if (!defined($me->{$option})) {
            my $query = qq"The option: ${option} was missing, please fill it in:";
            my $response = $me->{term}->readline($query);
            $response =~ s/\s+$//g;
            $response =~ s/\@|\*|\+//g;
            $me->{$option} = $response;
            if ($option eq 'input') {
                my $base = basename($me->{input}, @{$me->{suffixes}});
                $base = basename($base, @{$me->{suffixes}});
                $me->{basename} = $base;
            }
        }
        ## Make sure that no options start with ~ if they do, replace them with $home
        $me->{$option} =~ s/^\~/$ENV{HOME}/g;
    }  ## End iterating over every option
}

=item C<Get_Input>

    Get_Input() attempts to standardize the inputs passed to CYOA.
    It returns a stringified and standard representation of the likely
    input(s) to the script.

    There are a few problems with how I send input to these scripts:
    Sometimes I put in --hpgl hpgl0415 when I mean --hpgl HPGL0415,
    Sometimes I put in --input hpgl0415.fastq  when I mean hpgl0415.fastq.(gz|xz),
    Sometimes I put in -i hpgl0415.fastq.(gz|xz) when I mean hpgl0415.fastq,
    Sometimes I put in -i hpgl0415.fastq when I mean hpgl0415-trimmed.fastq(.gz|.xz)
    Sometimes I put in -i hpgl0415_forward.fastq:hpgl0415_reverse.fastq

    So, this function should make this unambiguous and consistent no matter what I type

=cut
sub Get_Input {
    my $me = shift;
    my $input = $me->{input};
    my $id = $me->{hpgl};
    my $actual = "";

    my @input_list = undef;
    if ($input =~ /:/) {
        @input_list = split(/:/, $input);
    } else {
        push(@input_list, $input);
    }

    foreach my $in (@input_list) {
        my $low = $in;
        $low =~ tr/[A-Z]/[a-z]/;
        unless ($in eq $low) {
            system(qq"mv ${in}.fastq ${low}.fastq");
            if (-r "${in}_forward.fastq") {
                system(qq"mv ${in}_forward.fastq ${low}_forward.fastq");
            }
            if (-r "${in}_reverse.fastq") {
                system(qq"mv ${in}_reverse.fastq ${low}_reverse.fastq");
            }
        }
##        if (-r "${in}" and $in =~ /\.gz$/) {
##            print "gunzip of ${in}\n";
##            system("nice gunzip ${in}");
##        }
##        if (-r "${in}" and $in =~ /\.xz$/) {
##            print "xz -d ${in}\n";
##           system("nice xz -d ${in}");
##        }
    }
    $input =~ tr/[A-Z]/[a-z]/;
##    $input =~ s/\.gz//g;
##    $input =~ s/\.xz//g;

    return($input);
}

=item C<Last_Stat>

    Last_Stat() reads the final line of an input file and returns it
    as a string.

    This is useful because many of these tools append to .csv files
    with summary information (alignment statistics, sequence sizes,
    etc) and the tests keep a set of expected outputs for the most
    recent run.

=cut
sub Last_Stat {
    my $me = shift;
    my %args = @_;
    my $input = new FileHandle;
    my $input_filename = $args{input};
    $input->open("<$input_filename");
    my ($line, $last);
    while ($line = <$input>) {
        chomp $line;
        ## I am doing this due to terminal newlines on the file, there is probably a much smrtr way.
        $last = $line unless ($line =~ /^$/);
    }
    $input->close();
    return($last);
}


=item C<Read_Genome_Fasta>

    Read a fasta file and return the chromosomes.

=cut
sub Read_Genome_Fasta {
    my $me = shift;
    my %args = @_;
    my $chromosomes = {};
    my $fasta_name = basename($args{fasta}, ['.fasta']);
    my $data_file = qq"$me->{basedir}/${fasta_name}.pdata";
    if (-r $data_file) {
        $chromosomes = retrieve($data_file);
    } else {
        my $input_genome = new Bio::SeqIO(-file => $args{fasta}, -format => 'Fasta');
        while (my $genome_seq = $input_genome->next_seq()) {
            next unless(defined($genome_seq->id));
            my $id = $genome_seq->id;
            my $sequence = $genome_seq->seq;
            print "Reading chromosome: $id\n";
            my $length = $genome_seq->length;
            my $empty_forward = [];
            my $empty_reverse = [];
            for my $c (0 .. $length) {
                $empty_forward->[$c] = 0;
                $empty_reverse->[$c] = 0;
            }
            $chromosomes->{$id}->{forward} = $empty_forward;
            $chromosomes->{$id}->{sequence} = $sequence;
            $chromosomes->{$id}->{reverse} = $empty_reverse;
        } ## End reading each chromosome
        store($chromosomes, $data_file);
    } ## End checking for a .pdata file
    return($chromosomes);
}

=item C<Read_GFF>

    Read a GFF file and extract the annotation information from it.

=cut
sub Read_Genome_GFF {
    my $me = shift;
    my %args = @_;
    ##my $gff = new FileHandle;
    ##$gff->open("<$args{gff}");
    my $feature_type = $me->{feature_type};
    $feature_type = $args{feature_type} if (defined($args{feature_type}));
    my $annotation_in = new Bio::Tools::GFF(-file => "$args{gff}", -gff_version => 3);
    my $gff_out = { stats => { chromosomes => [],
                               lengths => [],
                               feature_names => [],
                               cds_starts => [],
                               cds_ends => [],
                               inter_starts => [],
                               inter_ends => [],
                    },};
    my $gff_name = basename($args{gff}, ['.gff']);
    my $data_file = qq"$me->{basedir}/${gff_name}.pdata";
    if (-r $data_file and !$me->{debug}) {
        $gff_out = retrieve($data_file);
    } else {
        print "Starting to read gff: $args{gff}\n" if ($me->{debug});
        my $hits = 0;
        my @chromosome_list = @{$gff_out->{stats}->{chromosomes}};
        my @feature_names = @{$gff_out->{stats}->{feature_names}};
        my @cds_starts = @{$gff_out->{stats}->{cds_starts}};
        my @inter_starts = @{$gff_out->{stats}->{inter_starts}};
        my @cds_ends = @{$gff_out->{stats}->{cds_ends}};
        my @inter_ends = @{$gff_out->{stats}->{inter_ends}};
        my $start = 1;
        my $old_start = 1;
        my $end = 1;
        my $old_end = 1;
      LOOP: while(my $feature = $annotation_in->next_feature()) {
          ## print "In loop with type: $feature->{_primary_tag}\n" if ($me->{debug});
          next LOOP unless ($feature->{_primary_tag} eq $feature_type);
          $hits++;
          my $location = $feature->{_location};
          $old_start = $start;
          $old_end = $end;
          $start = $location->start();
          $end = $location->end();
          my $strand = $location->strand();
          my @ids = $feature->each_tag_value("ID");
          my $id = "";
          my $gff_chr = $feature->{_gsf_seq_id};
          my $gff_string = $annotation_in->gff_string($feature);
          foreach my $i (@ids) {
              $i =~ s/^cds_//g;
              $i =~ s/\-\d+$//g;
              $id .= "$i ";
          }
          $id =~ s/\s+$//g;
          my @gff_information = split(/\t+/, $gff_string);
          my $description_string = $gff_information[8];
          my $orf_chromosome = $gff_chr;
          ## Add the chromosome to the list of chromosomes if it is not there already.
          push(@chromosome_list, $orf_chromosome) if ($orf_chromosome !~~ @chromosome_list);
          push(@feature_names, $id);
          push(@cds_starts, $start);
          push(@inter_starts, $old_start+1);
          push(@cds_ends, $end);
          ##push(@inter_ends, $old_start-1);
          push(@inter_ends, $start-1);
          my $annot = {
              id => $id,
              start => $start,  ## Genomic coordinate of the start codon
              end => $end,      ## And stop codon
              strand => $strand,
              description_string => $description_string,
              chromosome => $gff_chr,
          };
          $gff_out->{$gff_chr}->{$id} = $annot;
      } ## End looking at every gene in the gff file
        $gff_out->{stats}->{chromosomes} = \@chromosome_list;
        $gff_out->{stats}->{feature_names} = \@feature_names;
        $gff_out->{stats}->{cds_starts} = \@cds_starts;
        $gff_out->{stats}->{cds_ends} = \@cds_ends;
        $gff_out->{stats}->{inter_starts} = \@inter_starts;
        $gff_out->{stats}->{inter_ends} = \@inter_ends;
        print STDERR "Not many hits were observed, do you have the right feature type?  It is: $me->{feature_type}\n" if ($hits < 1000);
        store($gff_out, $data_file);
    } ## End looking for the gff data file
    return($gff_out);
}

sub Pipeline_Riboseq {
    my $me = shift;
    my %args = @_;
    $me->Fastqc(%args);
    my $cutadapt_job = $me->Cutadapt(%args);
    $args{depends} = $cutadapt_job->{pbs_id};
    $me->Biopieces_Graph(%args);
    my $rrna_job = $me->Bowtie_RRNA(%args);
    $args{depends} = $rrna_job->{pbs_id};
    my $bt_jobs = $me->Bowtie(%args);
}

sub Pipeline_RNAseq_Bowtie {
    my $me = shift;
    my %args = @_;
    $args{aligner} = 'bowtie';
    $me->Pipeline_RNAseq(%args);
    return($me);
}

sub Pipeline_RNAseq_Bowtie2 {
    my $me = shift;
    my %args = @_;
    $args{aligner} = 'bowtie2';
    $me->Pipeline_RNAseq(%args);
    return($me);
}


sub Pipeline_RNAseq_Tophat {
    my $me = shift;
    my %args = @_;
    $args{aligner} = 'tophat';
    $me->Pipeline_RNAseq(%args);
    return($me);
}

sub Pipeline_RNAseq_BWA {
    my $me = shift;
    my %args = @_;
    $args{aligner} = 'bwa';
    $me->Pipeline_RNAseq(%args);
    return($me);
}

sub Pipeline_RNAseq_Kallisto {
    my $me = shift;
    my %args = @_;
    $args{aligner} = 'kallisto';
    $me->Pipeline_RNAseq(%args);
    return($me);
}

sub Pipeline_RNAseq {
    my $me = shift;
    my %args = @_;
    $me->Fastqc(%args);
    my $trim_job = $me->Trimomatic(%args);
    $args{depends} = $trim_job->{pbs_id};
    $me->Biopieces_Graph(%args);
    my $rrna_job = $me->Bowtie_RRNA(%args);
    $args{depends} = $rrna_job->{pbs_id};
    my $align_jobs;
    if ($args{aligner} eq 'bowtie') {
        $align_jobs = $me->Bowtie(%args);
    } elsif ($args{aligner} eq 'bowtie2') {
        $align_jobs = $me->Bowtie2(%args);
    } elsif ($args{aligner} eq 'tophat') {
        $align_jobs = $me->Tophat(%args);
    } elsif ($args{aligner} eq 'bwa') {
        $align_jobs = $me->BWA(%args);
    } elsif ($args{aligner} eq 'kallisto') {
        $align_jobs = $me->Kallisto(%args);
    } else {
        $align_jobs = $me->Tophat(%args);
    }
    return($me);
}

sub Pipeline_TNseq {
    my $me = shift;
    my %args = @_;
    $me->Fastqc(%args);
    $args{type} = 'tnseq';
    my $cutadapt_job = $me->Cutadapt(%args);
    $args{depends} = $cutadapt_job->{pbs_id};
    $me->Biopieces_Graph(%args);
    my $bt_jobs = $me->Bowtie(%args);
}

sub CYOA_Help {
    my $me = shift;
    my %args = @_;
    my %methods = %{$me->{methods}};
    print qq"The command line program 'cyoa' has a series of shortcuts intended to make it easy to use and flexible.
The following comprises the set of strings you may feed it as 'methods':\n";
    my $c = 0;
    for my $k (sort keys %methods) {
        my $sep = '\t';
        if (($c % 3) == 0) {
            $sep = '\n';
        } else {
            $sep = '\t';
        }
        $c++;
        print "${k}${sep}";
    }
    print "\n";
    print qq"cyoa uses GetOptions, so you can shortcut all the 'methods', so:
'cyoa --task ri --method cut --input test.fastq' calls the cutadapt with
  options suitable for ribosome profiling data.  Conversely:
'cyoa --task rna --method top --input test.fastq' calls tophat assuming
  rnaseq data.
'cyoa --method blastsplit --query test.fasta --library nr --blast_tool blastp'
  Splits the test.fasta into a bunch of pieces (settable with --number), calls
  blastp on them, merges the outputs, and parses the result into a table of hits.
";
    $me->Help();
}

=back

=head1 AUTHOR - atb

Email abelew@gmail.com

=head1 SEE ALSO

    L<Bio::Seq> L<common::sense> L<autodie> L<local::lib> L<CYOA::RNASeq_Aligners>
    L<CYOA::RNASeq_Assembly> L<CYOA::RNASeq_Count> L<CYOA::RNASeq_Aligners> L<CYOA::RNASeq_QA>
    L<CYOA::RNASeq_Trim> L<CYOA::Align_Blast> L<CYOA::Align_Fasta> L<CYOA::Align>
    L<CYOA::Ceph> L<CYOA::Cleanup> L<CYOA::Compress> L<CYOA::Convert> L<CYOA::PBS>
    L<CYOA::Prepare> L<CYOA::Riboseq> L<CYOA::SeqMisc> L<CYOA::SNP> L<CYOA::Status>
    L<CYOA::TNSeq>

=cut

1;
