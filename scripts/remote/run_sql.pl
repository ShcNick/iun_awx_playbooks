#!/usr/bin/perl

use strict;
use warnings;

use Const::Fast qw(const);
use Carp qw(croak);
use DBI;
use Getopt::Long;
use List::Util qw(first);
use POSIX qw(strftime ceil);
use Data::Dumper;

const my $_DB_TYPE_MYSQL  => 'mysql';
const my $_DB_TYPE_ORACLE => 'oracle';
const my $_DB_TYPE_ALL => 'sql';

my %_DB_Client = ($_DB_TYPE_MYSQL => "DbMySQLClient", $_DB_TYPE_ORACLE => "DbOracleClient");

my %_DB_DSN = (
    'billing'       => {$_DB_TYPE_MYSQL => 'master_dsn',      $_DB_TYPE_ORACLE => 'pbmaster_dsn'},
    'psmsc'         => {$_DB_TYPE_MYSQL => 'psmsc_dsn',       $_DB_TYPE_ORACLE => 'psmsc_dsn'},
    'reports'       => {$_DB_TYPE_MYSQL => 'reports_dsn',     $_DB_TYPE_ORACLE => 'reports_dsn'},
    'slave'         => {$_DB_TYPE_MYSQL => 'slave_dsn',       $_DB_TYPE_ORACLE => 'pbweb_dsn'},
    'billing-delta' => {$_DB_TYPE_MYSQL => 'pbdelta_dsn',     $_DB_TYPE_ORACLE => 'pbdelta_dsn'},
    'psmsc-delta'   => {$_DB_TYPE_MYSQL => 'psmsc_delta_dsn', $_DB_TYPE_ORACLE => 'psmsc_delta_dsn'},
    'dbmail'        => {$_DB_TYPE_MYSQL => 'dbmail_dsn',      $_DB_TYPE_ORACLE => 'dbmail_dsn'}
);


my $conf_db = 'configurator';
my @conf_dsn = ('DBI:mysql:database=porta-configurator;mysql_socket=/tmp/configurator-mysqld.sock','root','');

my $get_opt_cmd = '/home/porta-configurator/libexec/dv/dv_get_opt_val.pl';
my $datadir = "/porta_var/tmp/awx/";
my %_SQL = ();
my ( $db, $db_type );
my ( %args, $debug, $help );


sub _log {
   if ($debug) {
      my ( $level, $message, @args ) = @_;

      if (@args) {
          $message = sprintf( $message, @args );
      }

      my $time = strftime( '%Y-%m-%d %H:%M:%S', localtime );
      STDOUT->say("$time [$level] $message");
   }

   return undef;
}


sub usage {
    my ($exit_code) = @_;

    my $schema_list = $conf_db . ", " . join(", ", keys %_DB_DSN);
    my $help_message = <<"__USAGE__"
    This script exetutes SQL query for the defined DB schema

    Mandatory parameters:
    -o db_schema      alias for db schema from the list: $schema_list
    -o sql_prefix     source for sql text (SQL files should be placed to: $datadir)

    Additional parameters:
    -o dsn_mysql      specific DSN names for Mysql and Oracle 
    -o dsn_oracle     (used in pair instead of db_schema, should be defined in Configuration)
                      e.g.: -o dsn_mysql=slave_dsn -o dsn_oracle=pbweb_dsn
    --help            show this help
    --debug           show verbose output

__USAGE__
        ;

    if ($exit_code) { STDERR->say("Error: missing mandatory parameters.\nHelp: $0 --help"); }
    else { STDERR->say($help_message); }

    exit $exit_code;
} ## end sub usage


sub _connect {
    my $args = shift;

    my $connect_options = { RaiseError => 1, FetchHashKeyName => 'NAME_lc' };
    $db = DBI->connect( $args->{db_dsn},$args->{db_user},$args->{db_password}, $connect_options ) || croak('Failed to connect to DB');

    $db_type
        = ( $args->{db_dsn} =~ m/oracle/i )
        ? $_DB_TYPE_ORACLE
        : $_DB_TYPE_MYSQL;

    return undef;
}

sub _run_sql {
   my $sth = $db->prepare( $_SQL{$db_type} );
   $sth->execute;
   my @row = ();
   _log("INFO","Result:");
   while (@row = $sth->fetchrow_array) {
      print join(" | ", map { defined($_) ? $_ : '' } @row)."\n"; 
   } 

   return undef;
}

sub _disconnect {
    $db->disconnect;
    return undef;
}

sub _get_db_engine {
  my $res;
  my $cmd='eval "$(' . $get_opt_cmd . ' -n PortaSwitch -o "DatabaseServer.database_engine" --var-name DBOPTS)"; echo "${DBOPTS["DatabaseServer.database_engine"]}"';
  _log("DEBUG", "cmd for DB engine:\n$cmd");
  my $xx = qx/$cmd/;
  chomp $xx;
  if ($xx =~ m/oracle/i) {$res = $_DB_TYPE_ORACLE }
    elsif ($xx =~ m/mysql/i) {$res = $_DB_TYPE_MYSQL };

  return $res;
}

sub _get_db_dsn {
  my $args = shift;
  my $db_schema = $args->{db_schema} // "";
  my %res;
  my $dsn;

  $db_type = _get_db_engine() // $_DB_TYPE_MYSQL;
  _log("DEBUG", "DB type: $db_type");

  if ($db_schema) {
    $dsn = $_DB_DSN{$db_schema}{$db_type};
    if (!$dsn) { die "Unknown DSN for '$db_schema'"; }
  } else {
    $dsn = $args->{"dsn_" . $db_type}
  }

  _log("DEBUG","DSN: $dsn");
  my $cl = $_DB_Client{$db_type}.".";
  my $user = $dsn =~ s/_dsn/_user/r;
  my $pass = $dsn =~ s/_dsn/_password/r;

  my $cmd1 = 'eval "$(' . $get_opt_cmd . ' -n PortaSwitch -o "' . $cl.$dsn . '" -o "' . $cl.$user . '" -o "' . $cl.$pass . '" --var-name DBOPTS )"';
  my $cmd2 = 'echo -e "${DBOPTS["' . $cl.$dsn . '"]}\n${DBOPTS["' . $cl.$user . '"]}\n${DBOPTS["' . $cl.$pass .'"]}"';
  _log("DEBUG","cmd for DB access:\n$cmd1 ; $cmd2");
  my $cmd = $cmd1 . ";" . $cmd2;
  my @xx = qx/$cmd/;
  map { s/^\s+|\s+$//g; } @xx;
  if ((scalar @xx == 3) and ($xx[0] gt "")) {
     @res{qw(db_dsn db_user db_password)} = @xx 
  }

  return %res;
}


sub _get_db_opts {
  my $args = shift;
  my %res = ();
  if ($args->{db_schema} eq $conf_db) {
     @res{qw(db_dsn db_user db_password)} = @conf_dsn 
  }
  else {
    %res = _get_db_dsn($args);
  }
  if (!%res) { die "ERROR: DSN is undefined." };
  _log("DEBUG", "DSN params: " . Dumper(\%res));
  return \%res;
}


sub _read_query_text {
  my $pref = shift || die "SQL perfix is not specified";

  for my $type ($_DB_TYPE_MYSQL, $_DB_TYPE_ORACLE, $_DB_TYPE_ALL) {
    my $fname = $datadir . $pref . "." . $type;
    my $content = '';
    if (open(my $fh, '<', $fname)) {
      $content = do { local $/; <$fh> };
      close $fh;
    }
    if ($content) { chomp $content; $_SQL{$type} = $content; }; 
  }

  # use global SQL when Mysql/Oracle SQL is absent
  if (defined($_SQL{$_DB_TYPE_ALL})) {
    for my $type ($_DB_TYPE_MYSQL, $_DB_TYPE_ORACLE) {
      if (not defined($_SQL{$type})) {$_SQL{$type} = $_SQL{$_DB_TYPE_ALL}};
    }
  }

  _log("DEBUG", "SQL queries:\n" . Dumper(\%_SQL));
  if (not defined($_SQL{$_DB_TYPE_MYSQL}) or not defined($_SQL{$_DB_TYPE_ORACLE})) { die "ERROR: SQL files were not found in $datadir" };
  return undef;
}

sub _check_input {

  GetOptions("opts|o=s" => \%args, "debug|d!" => \$debug, "help|h!" => \$help );

  if ($help) { usage(0) };

  if ( ( first { !$args{$_} } qw(db_schema sql_prefix) ) 
     and ( first { !$args{$_} } qw(sql_prefix dsn_mysql dsn_oracle) ) ) 
  {
    usage(1);
  }

  return undef;
}

sub main {

    _check_input();
    _log("INFO", "Main part...");

    _read_query_text($args{sql_prefix});
    my $db_args = _get_db_opts(\%args);
    _connect($db_args);
    _run_sql();
    _disconnect();

    return undef;
}

main();
