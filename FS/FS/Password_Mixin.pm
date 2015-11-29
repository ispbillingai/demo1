package FS::Password_Mixin;

use FS::Record qw(qsearch);
use FS::Conf;
use FS::password_history;
use Authen::Passphrase;
use Authen::Passphrase::BlowfishCrypt;
# https://rt.cpan.org/Ticket/Display.html?id=72743
use Data::Password qw(:all);

our $DEBUG = 0;
our $conf;
FS::UID->install_callback( sub {
  $conf = FS::Conf->new;
});

our $me = '[' . __PACKAGE__ . ']';

our $BLOWFISH_COST = 10;

=head1 NAME

FS::Password_Mixin - Object methods for accounts that have passwords governed
by the password policy.

=head1 METHODS

=over 4

=item is_password_allowed PASSWORD

Checks the password against the system password policy. Returns an error
message on failure, an empty string on success.

This MUST NOT be called from check(). It should be called by the office UI,
self-service ClientAPI, or other I<user-interactive> code that processes a
password change, and only if the user has taken some action with the intent
of changing the password.

=cut

sub is_password_allowed {
  my $self = shift;
  my $password = shift;

  # basic checks using Data::Password;
  # options for Data::Password
  $DICTIONARY = 4;   # minimum length of disallowed words
  $MINLEN = $conf->config('passwordmin') || 6;
  $MAXLEN = $conf->config('passwordmax') || 8;
  $GROUPS = 4;       # must have all 4 'character groups': numbers, symbols, uppercase, lowercase
  # other options use the defaults listed below:
  # $FOLLOWING = 3;    # disallows more than 3 chars in a row, by alphabet or keyboard (ie abcd or asdf)
  # $SKIPCHAR = undef; # set to true to skip checking for bad characters
  # # lists of disallowed words
  # @DICTIONARIES = qw( /usr/share/dict/web2 /usr/share/dict/words /usr/share/dict/linux.words );

  my $error = IsBadPassword($password);
  $error = 'must contain at least one each of numbers, symbols, and lowercase and uppercase letters'
    if $error eq 'contains less than 4 character groups'; # avoid confusion
  $error = 'Invalid password - ' . $error if $error;
  return $error if $error;

  #check against known usernames
  my @disallowed_names = $self->password_disallowed_names;
  foreach my $noname (@disallowed_names) {
    if ($password =~ /$noname/i) {
      #keeping message ambiguous to avoid leaking personal info
      return 'Password contains a disallowed word';
    }
  }

  return '' unless $self->get($self->primary_key); # for validating new passwords pre-insert

  my $no_reuse = 3;
  # allow override here if we really must

  if ( $no_reuse > 0 ) {

    # "the last N" passwords includes the current password and the N-1
    # passwords before that.
    warn "$me checking password reuse limit of $no_reuse\n" if $DEBUG;
    my @latest = qsearch({
        'table'     => 'password_history',
        'hashref'   => { $self->password_history_key => $self->get($self->primary_key) },
        'order_by'  => " ORDER BY created DESC LIMIT $no_reuse",
    });

    # don't check the first one; reusing the current password is allowed.
    shift @latest;

    foreach my $history (@latest) {
      warn "$me previous password created ".$history->created."\n" if $DEBUG;
      if ( $history->password_equals($password) ) {
        my $message;
        if ( $no_reuse == 1 ) {
          $message = "This password is the same as your previous password.";
        } else {
          $message = "This password was one of the last $no_reuse passwords on this account.";
        }
        return $message;
      }
    } #foreach $history

  } # end of no_reuse checking

  '';
}

=item password_disallowed_names

Override to return a list additional words (eg usernames) not
to be used by passwords on this service.

=cut

sub password_disallowed_names {
  return ();
}

=item password_history_key

Returns the name of the field in L<FS::password_history> that's the foreign
key to this table.

=cut

sub password_history_key {
  my $self = shift;
  $self->table . '__' . $self->primary_key;
}

=item insert_password_history

Creates a L<FS::password_history> record linked to this object, with its
current password.

=cut

sub insert_password_history {
  my $self = shift;
  my $encoding = $self->_password_encoding;
  my $password = $self->_password;
  my $auth;

  if ( $encoding eq 'bcrypt' ) {
    # our format, used for contact and access_user passwords
    my ($cost, $salt, $hash) = split(',', $password);
    $auth = Authen::Passphrase::BlowfishCrypt->new(
      cost        => $cost,
      salt_base64 => $salt,
      hash_base64 => $hash,
    );

  } elsif ( $encoding eq 'crypt' ) {

    # it's smart enough to figure this out
    $auth = Authen::Passphrase->from_crypt($password);

  } elsif ( $encoding eq 'ldap' ) {

    $password =~ s/^{PLAIN}/{CLEARTEXT}/i; # normalize
    $auth = Authen::Passphrase->from_rfc2307($password);
    if ( $auth->isa('Authen::Passphrase::Clear') ) {
      # then we've been given the password in cleartext
      $auth = $self->_blowfishcrypt( $auth->passphrase );
    }
  
  } else {
    warn "unrecognized password encoding '$encoding'; treating as plain text"
      unless $encoding eq 'plain';

    $auth = $self->_blowfishcrypt( $password );

  }

  my $password_history = FS::password_history->new({
      _password => $auth->as_rfc2307,
      created   => time,
      $self->password_history_key => $self->get($self->primary_key),
  });

  my $error = $password_history->insert;
  return "recording password history: $error" if $error;
  '';

}

=item _blowfishcrypt PASSWORD

For internal use: takes PASSWORD and returns a new
L<Authen::Passphrase::BlowfishCrypt> object representing it.

=cut

sub _blowfishcrypt {
  my $class = shift;
  my $passphrase = shift;
  return Authen::Passphrase::BlowfishCrypt->new(
    cost => $BLOWFISH_COST,
    salt_random => 1,
    passphrase => $passphrase,
  );
}

=back

=head1 SEE ALSO

L<FS::password_history>

=cut

1;