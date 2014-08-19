#!/opt/perl-5.20.0/bin/perl

use strict;
use warnings;
use PHP::Include;
use CWB;
use CWB::CQP;
use CGI qw/:standard/;
use Data::Dumper;
my $JQUERY = 'jquery.js';

require '/var/www/cgi-bin/biblioteca_corpora.pl';
include_php_vars("/var/www/html/acesso/var_corpora.php");
#line 16
# put above the line number for this line, for decent error reporting.

$Data::Dumper::Indent = 0;

our $DEBUG = 0;
our $token_rx = qr{  \??
                    ([a-zA-Z]+)  (  (?: _[a-zA-Z]+ )?  )
                    (?: \+\d+ )?
                    (?:  =/  ([^/]+)  /  c?d?  )?
              }x;
our $MAXHITS = 5000;

my  $action      = param("action") || "begin";
our $tipo_output = param("output") || "html";

if (!param("output") || param("output") ne "tsv") {
    print full_header();
    show_form();
    if ($action eq "begin") {
        print attribute_table();
    } else {
        print div({id=>'wait'}, img({src=>'aguarde.gif'}));
    }
}

if ($action ne "begin") {
    if ($action eq "query") {
        my $error;
        if (!($error = query_is_valid(param("corpo") => param("query")))) {
            show_results();
        } else {
            show_error($error);
        }
    }
    else {
        show_error();
    }
}
print full_footer() unless $tipo_output eq "tsv";

exit 0; # just to say so...

sub query_is_valid {
    my ($cp, $query) = @_;
    my $error = undef;

    $error = "Corpo '$cp' é inválido" unless exists $corpora{$cp};

    if (!$error) {
        my $cqp = CWB::CQP->new("-r /home/registo");
        my $attr = attributes($cqp, $cp, hash_form => 1);
        while (!$error && $query =~ s/\s*$token_rx//) {
            my $a = $1;
            $error = "Atributo '$a' não existe no corpus '$cp'" unless exists $attr->{$a};
        }
        $error = "Expressão de pesquisa inválida: <tt>[$query]</tt>" if $query !~ /^\s*$/;
    }
    return $error;
}

sub divide_query {
    my $query = shift;
    my @query = ();
    while ($query =~ s/^\s*($token_rx)//) {
        push @query, $1;
    }
    return @query;
}


sub fix_query_for_cwb {
    my @x = @_;
    map {
        my $rx = qr/^(.+)$/;
        if ($_ =~ $token_rx && $1 && $2 && $3) {
            my $cwb_attr = $1;
            my $xml_attr = substr($2, 1);
            my $querystr = $3;

            $querystr =~ s/ /=/g;

            $_ =~ s/${cwb_attr}_${xml_attr}/$cwb_attr/;
            $_ =~ s{/(.+)/}{/.*$xml_attr="?${querystr}"?.*/};

            $rx = qr/$xml_attr="?(.+?)"?(?: |$)/;
        } elsif ($1 && $2) {
            my $cwb_attr = $1;
            my $xml_attr = substr($2, 1);

            $_ =~ s/${cwb_attr}_${xml_attr}/$cwb_attr/;

            $rx = qr/$xml_attr="?(.+?)"?(?: |$)/;
        }

        $rx = undef if /^\?/;

        [ $_ , $rx ]
    } @x;
}

sub get_results {
    my ($str, $array) = @_;
    my @str = split /\t+/ => $str;
    my $i = 0;
    my $id = shift @str;
    @str = map {
        /$array->[$i]/; $i++; $_ = $1;
    } @str;
    push @str => $id;

    @str
}

sub show_results {
    my $scancorpus = $CWB::ScanCorpus;
    my $corpo      = param("corpo");
    my $query      = param("query");
    my @query      = divide_query($query);
    my @exp_query  = fix_query_for_cwb(@query);
    my $cwb_query  = join(" ", map { "'" . $_->[0] . "'" } @exp_query);
    my $regexps    = [map { defined($_->[1]) ? $_->[1] : () } @exp_query];

    _log();

    my $output     = `$scancorpus -q -r /home/registo $corpo $cwb_query`;

    @query = grep { $_ !~ /^\?/ } @query;

    my $t;
    if ($?) {
        show_error($?);
        $DEBUG && print pre($cwb_query);
    } else {

        if ($tipo_output eq "html" && $DEBUG) {

            print pre("\@query = ", join(" ", map { "[$_]" } @query));
            print pre($cwb_query);
            print pre($regexps);
        }

        $output = [map { [ get_results($_ => $regexps) ] } split /\n/ => $output];

        my $i = 0;
        if ($tipo_output ne "tsv") {
            print p("A apresentar os $MAXHITS resultados com mais ocorrências",
                    " de um total de $t resultados.") if ($t = scalar(@$output)) > $MAXHITS;

            print p("Não foram encontradas ocorrências!") unless $t;
        }

        if ($tipo_output ne "tsv") {
            print "<table id='results'>";
            print Tr(th([$query[0], 'Frequência Total', @query[1..$#query], 'Frequência Parcial', '%']));
        } else {
            print header(-content_disposition => "attachment; filename=distribuicao.tsv",
                         -type => 'text/plain');
        }
        my $pl = undef;

        my $groups = group($output);
        my @out = map {
            $groups->{$_}{key} = $_; $groups->{$_}
        } sort { $groups->{$b}{count} <=> $groups->{$a}{count} } keys %$groups;

        my $tot = min($MAXHITS, scalar(@out)) - 1;

        for my $k ( @out[0..$tot] ) {

            my $key = $k->{key};
            my $tot = $k->{count};
            my @hits = sort { $a->[0] cmp $b->[0] } @{$k->{hits}};
            if ($tipo_output ne "tsv") {
                my $nchilds = scalar(@{$k->{hits}});
                print Tr(td( { -rowspan => $nchilds }, _protect($key)),
                         td( { -rowspan => $nchilds }, $tot),
                         td( _protect($hits[0]) ), td({-style=>"text-align: right"}, 
                                _my_format($hits[0][-1]*100/$tot)));
                shift @hits;
                for my $x (@hits) {
                    print Tr(td( _protect($x) ),
                             td({-style=>"text-align: right"}, _my_format($x->[-1]*100/$k->{count})));
                }
            } else {

                for my $x (@hits) {
                    my $cols = join "\t", @$x;
                    my $rel = $hits[0][-1] * 100 / $tot;
                    printf "%s\t%d\t%s\t%.2f\n", $key, $tot, $cols, $rel;
                }
     #           print join("\t", @$l, "\n");
            }
            $i++;

            ## $pl = $l;
        }
        if ($tipo_output ne "tsv") {
            print "</table>";
            print full_footer();
        }
    }
}

sub _my_format {
    my $perc = shift;
    my $s = sprintf("%.2f%%", $perc);
    $s =~ s/\./,/;
    return $s;
}

sub group {
    my $output = shift;
    my $result = {};
    for my $line (@$output) {
        my $key   = shift @$line;
        my $count = $line->[-1];

        push @{$result->{$key}{hits}} => $line;
        $result->{$key}{count} += $count;
    }
    return $result;
}

sub show_form {
    print start_form(-style => 'text-align: center', action=>'distribuidor.pl');
    print hidden(-override => 1, -name => 'action', -value => 'query');
    print p(b('Expressão de pesquisa: '), textfield(-name => 'query', -size => 50));
    print p(b('Corpo: '),
            popup_menu(-name=>'corpo', -default=>'CHAVE', -values=>[sort keys %corpora]),
            "&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;",
            b('Tipo de resultado: '),
            popup_menu(-name=>'output', -default=>'html', -values=>['html','tsv']));
    print p(submit(-id => 'procurar', -disabled => 'disabled',
                   -name => 'bt', -value => ' procurar '));
    print end_form;
}

sub attribute_table {
    my $cqp = new CWB::CQP("-r /home/registo");

    my $table = '<table id="table">';
    $table .= Tr(th(['Corpo','Atributos Estruturais','Atributos Posicionais']));
    for my $c (keys %corpora) {
        my $attr = attributes($cqp, $c);
        $table .= Tr(td([$c, join(", " => @{$attr->{s}}), join(", " => @{$attr->{p}})]));
    }
    $table .= '</table>';

    undef $cqp;
    return $table;
}

sub attributes {
    my ($cqp, $cp, %ops) = @_;
    $cqp->exec(uc $cp);

    my @attributes = $cqp->exec("show cd;");
    my $attributes;
    for (@attributes) {
        my @line = split /\t/;
        if ($ops{hash_form}) {
            $attributes->{$line[1]} = $1 if $line[0] =~ /([ps])-Att/;
        } else {
            push @{$attributes->{p}}, $line[1] if $line[0] =~ /p-Att/;
            push @{$attributes->{s}}, $line[1] if $line[0] =~ /s-Att/;
        }
    }
    return $attributes;
}

sub show_error {
    print h3("Erro!");
    if (@_) {
        print join("\n", map { p($_) } @_ );
    } else {
        print "Acesso ilegal.";
    }
    print full_footer();
}


sub match {
    my ($a, $b) = @_;

    my $size  = min(scalar(@$a), scalar(@$b));
    my $i     = 0;
    my $equal = 1;
    while ($i < $size-1 && $equal) {
        if ($a->[$i] eq $b->[$i]) {
            $a->[$i] =~ s/./ /g;
        } else {
            $equal = 0;
        }
        ++$i
    }
    return $a;
}

## HTML auxiliary functions

sub full_footer {
    join("", "</div>", end_html);
}

sub full_header {
    join("",
         header,
         start_html( -title  => 'Distribuidor',
                     -style  => { 'src'=>'distribuidor.css'},
                     -script => [
                                 { -language => 'JavaScript',
                                   -src =>  $JQUERY },
                                 { -language => 'JavaScript',
                                   -code => JS() },
                                ]),
         div({-id => 'linguateca'},
			div(a({-href=>"http://linguateca.pt"}, "Linguateca"),
					   a({-href=>"http://linguateca.pt/ACDC"}, "AC/DC"),
                       a({-href=>"ajuda.html"},"Ajuda")),
         h1('Distribuidor')),
         "<div id='content'>"
        );
}

sub CSS {
    <<EOCSS;

EOCSS
}

sub JS {
    <<'EOT';
  $(document).ready(
      function() {
           $('#wait').css('display', 'none');
           $('#procurar').removeAttr('disabled');
      }
  );
EOT
}


sub my_sort {
    my ($a, $b) = @_;

    my $size  = min(scalar(@$a), scalar(@$b));
    my $res   = 0;
    my $i     = 0;
    while ($i < $size - 1 && !$res) {
        $res = $a->[$i] cmp $b->[$i];
        ++$i;
    }
    return $res;
}

sub min { $_[0] > $_[1] ? $_[1] : $_[0] }

## Se receber uma referencia (para array) retorna uma referencia para
## array com todos os elementos protegidos.
##
## Se receber outra coisa, cria uma referencia de array com esse elemento,
## invoca o _protect, e retorna de novo o primeiro elemento do array 
sub _protect {
    if (ref $_[0] eq "ARRAY") {
       return [ map { 
                   s/&/&amp;/g;
                   s/</&lt;/g;
                   s/>/&gt;/g;
                   $_;
                }  @{$_[0]} ];
    }
    else {
        return _protect([$_[0]])->[0];
    }
}


sub _log {
    open LOG, ">>:utf8", "distribuidor.log" or return;
    my $date = localtime;
    printf LOG "[$date|%s] %s ==> %s\n",
      $ENV{REMOTE_ADDR}, param('corpo'), param('query');
    close LOG;
}
