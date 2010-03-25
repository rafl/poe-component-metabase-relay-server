package POE::Component::Metabase::Relay::Server;

use strict;
use warnings;
use CPAN::Testers::Report;
use POE qw[Filter::Stream];
use POE::Component::Metabase::Relay::Server::Queue;
use Test::POE::Server::TCP;
use Carp                      ();
use Storable                  ();
use JSON                      ();
use Metabase::User::Profile   ();
use Metabase::User::Secret    ();
use vars qw[$VERSION];

$VERSION = '0.02';

my @fields = qw(
  osversion
  distfile
  archname
  textreport
  osname
  perl_version
  grade
);

use MooseX::POE;
use MooseX::Types::Path::Class qw[File];
use MooseX::Types::URI qw[Uri];
 
has 'debug' => (
  is => 'rw',
  isa => 'Bool',
  default => 0,
);

has 'address' => (
  is => 'ro',
);
 
has 'port' => (
  is => 'ro',
  default => sub { 0 },
  writer => '_set_port',
);
 
has 'id_file' => (
  is       => 'ro',
  required => 1,
  isa      => File,
  coerce   => 1,
);

has 'dsn' => (
  is => 'ro',
  isa => 'Str',
  required => 1,
);

has 'uri' => (
  is => 'ro',
  isa => Uri,
  coerce => 1,
  required => 1,
);

has 'username' => (
  is => 'ro',
  isa => 'Str',
  default => '',
);

has 'password' => (
  is => 'ro',
  isa => 'Str',
  default => '',
);

has 'db_opts' => (
  is => 'ro',
  isa => 'HashRef',
  default => sub {{}},
);

has '_profile' => (
  is => 'ro',
  isa => 'Metabase::User::Profile',
  init_arg => undef,
  writer => '_set_profile',
);
 
has '_secret' => (
  is => 'ro',
  isa => 'Metabase::User::Secret',
  init_arg => undef,
  writer => '_set_secret',
);
 
has '_relayd' => (
  accessor => 'relayd',
  isa => 'Test::POE::Server::TCP',
  lazy_build => 1,
  init_arg => undef,
);

has '_queue' => (
  accessor => 'queue',
  isa => 'POE::Component::Metabase::Relay::Server::Queue',
  lazy_build => 1,
  init_arg => undef,
);
 
has '_requests' => (
  is => 'ro',
  isa => 'HashRef',
  default => sub {{}},
  init_arg => undef,
);

sub _build__relayd {
  my $self = shift;
  Test::POE::Server::TCP->spawn(
     address => $self->address,
     port => $self->port,
     prefix => 'relayd',
     filter => POE::Filter::Stream->new(),
  );
}

sub _build__queue {
  my $self = shift;
  POE::Component::Metabase::Relay::Server::Queue->spawn(
    dsn      => $self->dsn,
    username => $self->username,
    password => $self->password,
    db_opts  => $self->db_opts,
    uri      => $self->uri->as_string,
    profile  => $self->_profile,
    secret   => $self->_secret,
    debug    => $self->debug,
  );
}

sub spawn {
  shift->new(@_);
}
 
sub START {
  my ($kernel,$self) = @_[KERNEL,OBJECT];
  $self->_load_id_file;
  $self->relayd;
  $self->queue;
  warn ref $self->id_file, "\n" if $self->debug;
  return;
}

event 'shutdown' => sub {
  my ($kernel,$self) = @_[KERNEL,OBJECT];
  $self->relayd->shutdown;
  $kernel->post( 
    $self->queue->get_session_id,
    'shutdown',
  );
  return;
};
 
event 'relayd_registered' => sub {
  my ($kernel,$self,$relayd) = @_[KERNEL,OBJECT,ARG0];
  return unless $self->debug;
  warn ref $relayd, "\n";
  warn $relayd->port, "\n";
  return;
};
 
event 'relayd_connected' => sub {
  my ($kernel,$self) = @_[KERNEL,OBJECT];
  warn "Client connected\n" if $self->debug;
  return;
};
 
event 'relayd_disconnected' => sub {
  my ($kernel,$self,$id) = @_[KERNEL,OBJECT,ARG0];
  warn "Client Close '$id'\n" if $self->debug;
  my $data = delete $self->_requests->{$id};
  my $report = eval { Storable::thaw($data); };
  return unless $report and ref $report eq 'HASH';
  $kernel->yield( 'process_report', $report );
  return;
};
 
event 'relayd_client_input' => sub {
  my ($kernel,$self,$id,$data) = @_[KERNEL,OBJECT,ARG0,ARG1];
  $self->_requests->{$id} .= $data;
  return;
};

event 'process_report' => sub {
  my ($kernel,$self,$data) = @_[KERNEL,OBJECT,ARG0];
  my @present = grep { defined $data->{$_} } @fields;
  return unless scalar @present == scalar @fields;
  # Build CPAN::Testers::Report with its various component facts.
  my $metabase_report = eval { CPAN::Testers::Report->open(
    resource => 'cpan:///distfile/' . $data->{distfile}
  ); };

  return unless $metabase_report;

  warn $data->{distfile}, "\n" if $self->debug;
  $metabase_report->add( 'CPAN::Testers::Fact::LegacyReport' => {
    map { ( $_ => $data->{$_} ) } qw(grade osname osversion archname perl_version textreport)
  });

  # TestSummary happens to be the same as content metadata 
  # of LegacyReport for now
  $metabase_report->add( 'CPAN::Testers::Fact::TestSummary' =>
    [$metabase_report->facts]->[0]->content_metadata()
  );

  $metabase_report->close();

  $kernel->yield( 'submit_report', $metabase_report );
  return;
};

event 'submit_report' => sub {
  my ($kernel,$self,$report) = @_[KERNEL,OBJECT,ARG0];
  $kernel->post( 
    $self->queue->get_session_id,
    'submit',
    $report,
  );
  return;
};

sub _load_id_file {
  my $self = shift;
  
  open my $fh, '<', $self->id_file
    or Carp::confess __PACKAGE__. ": could not read ID file '$self->id_file'"
    . "\n$!";
  
  my $data = JSON->new->decode( do { local $/; <$fh> } );

  my $profile = eval { Metabase::User::Profile->from_struct($data->[0]) }
    or Carp::confess __PACKAGE__ . ": could not load Metabase profile\n"
    . "from '$self->id_file':\n$@";

  my $secret = eval { Metabase::User::Secret->from_struct($data->[1]) }
    or Carp::confess __PACKAGE__ . ": could not load Metabase secret\n"
    . "from '$self->id_file':\n $@";

  $self->_set_profile( $profile );
  $self->_set_secret( $secret );
  return 1;
}



no MooseX::POE;
 
__PACKAGE__->meta->make_immutable;
 
1;

__END__
