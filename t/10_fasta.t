# -*-Perl-*-
BEGIN {
    use Test::More qw"no_plan";
    use HPGL;
    use File::Path qw"remove_tree";
    use File::Copy qw"cp";
    use String::Diff qw( diff_fully diff diff_merge diff_regexp );
}

diag("Copying data file to cwd().");
ok(cp("t/data/genome/phix.fasta", "phix.fasta"));
ok(cp("t/data/genome/phix.gff", "phix.gff"));

my $hpgl = new HPGL(pbs => 0, species => 'phix', libdir => 't/data');
diag("Converting the phix genome to CDS sequences.");
ok($hpgl->Gff2Fasta(genome => 'phix.fasta', gff => 'phix.gff', feature_type => 'gene'));
ok($hpgl->Split_Align_Fasta(query => 'phix_cds_nt.fasta', library => 'phix_cds_nt.fasta', number => 1, parse => 0));
