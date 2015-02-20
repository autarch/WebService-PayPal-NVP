package WebService::PayPal::NVP;

use Moo;
use DateTime;
use LWP::UserAgent ();
use MooX::Types::MooseLike::Base qw( InstanceOf );
use URI::Escape qw/uri_escape uri_escape_utf8 uri_unescape/;
use WebService::PayPal::NVP::Response;

with 'WebService::PayPal::NVP::Requests';

our $VERSION = '0.004';

has 'errors' => (
    is => 'rw',
    isa => sub {
        die "errors expects an array reference!\n"
            unless ref $_[0] eq 'ARRAY';
    },
    default => sub { [] },
);

has 'ua' => (
    is      => 'ro',
    isa     => InstanceOf['LWP::UserAgent'],
    builder => '_build_ua'
);

has 'user' => ( is => 'rw', required => 1 );
has 'pwd'  => ( is => 'rw', required => 1 );
has 'sig'  => ( is => 'rw', required => 1 );
has 'url'  => ( is => 'rw' );
has 'branch' => ( is => 'rw', default => sub { 'sandbox' } );
has 'api_ver' => ( is => 'rw', default => sub { 51.0 } );

sub BUILDARGS {
    my ($class, %args) = @_;
    # detect URL if it's missing
    if (not $args{url}) {
        $args{url} = "https://api-3t.sandbox.paypal.com/nvp"
            if $args{branch} eq 'sandbox';

        $args{url} = "https://api-3t.paypal.com/nvp"
            if $args{branch} eq 'live';
    }

    return \%args;
}

sub _build_ua {
    my $self = shift;

    my $lwp = LWP::UserAgent->new;
    $lwp->agent("p-Webservice-PayPal-NVP/${VERSION}");
    return $lwp;
}

sub _do_request {
    my ($self, $args) = @_;

    my $req = HTTP::Request->new(POST => $self->url);
    $req->content_type('application/x-www-form-urlencoded');

    my $authargs = {
        user      => $self->user,
        pwd       => $self->pwd,
        signature => $self->sig,
        version   => $args->{version}||$self->api_ver,
        subject   => $args->{subject}||'',
    };

    my $allargs = { %$authargs, %$args };
    my $content = $self->_build_content( $allargs );
    $req->content($content);
    my $res = $self->ua->request($req);

    unless ($res->code == 200) {
        $self->errors(["Failure: " . $res->code . ": " . $res->message]);
        return;
    }

    my $resp = { map { uri_unescape($_) }
        map { split '=', $_, 2 }
            split '&', $res->content };

    my $res_object = WebService::PayPal::NVP::Response->new(
        branch => $self->branch
    );

    if ($resp->{ACK} ne 'Success') {
        $res_object->errors([]);
        my $i = 0;
        while(my $err = $resp->{"L_LONGMESSAGE${i}"}) {
            push @{$res_object->errors},
                $resp->{"L_LONGMESSAGE${i}"};
            $i += 1;
        }

        $res_object->success(0);
    }
    else {
        $res_object->success(1);
    }

    {
        no strict 'refs';
        no warnings 'redefine';
        foreach my $key (keys %$resp) {
            my $val    = $resp->{$key};
            my $lc_key = lc $key;
            if ($lc_key eq 'timestamp') {
                if ($val =~ /(\d+)-(\d+)-(\d+)T(\d+):(\d+):(\d+)Z/) {
                    my ($day, $month, $year, $hour, $min, $sec)
                     = ($3, $2, $1, $4, $5, $6);
                    
                    $val = DateTime->new(
                        year    => $year,
                        month   => $month,
                        day     => $day,
                        hour    => $hour,
                        minute  => $min,
                        second  => $sec,
                    );
                }
            }
            *{"WebService::PayPal::NVP::Response::$lc_key"} = sub {
                return $val;
            };
        }
    }
    return $res_object; 
}

sub _build_content {
    my ($self, $args) = @_;
    my @args;
    for my $key (keys %$args) {
        $args->{$key} = defined $args->{$key} ? $args->{$key} : '';
        push @args,
            uc(uri_escape($key)) . '=' . uri_escape_utf8($args->{$key});
    }

    return (join '&', @args) || '';
}

1;
__END__

=head1 NAME

WebService::PayPal::NVP - PayPal NVP API

=head1 DESCRIPTION

A pure object oriented interface to PayPal's NVP API (Name-Value Pair). A lot of the logic in this module was taken from L<Business::PayPal::NVP>. I re-wrote it because it wasn't working with Catalyst adaptors and I couldn't save instances of it in Moose-type accessors. Otherwise it worked fine. So if you don't need that kind of support you should visit L<Business::PayPal::NVP>!.
Another difference with this module compared to Business::PayPal::NVP is that the keys may be passed as lowercase. Also, a response will return a WebService::PayPal::NVP::Response object where the response values are methods. Timestamps will automatically be converted to DateTime objects for your convenience.


=head1 SYNOPSIS

    my $nvp = WebService::PayPal::NVP->new(
        user   => 'user.tld',
        pwd    => 'xxx',
        sig    => 'xxxxxxx',
        branch => 'sandbox',
        # optional:
        ua     => LWP::UserAgent->new( ... ),
    );
    
    my $res = $nvp->set_express_checkout({
        DESC              => 'Payment for something cool',
        AMT               => 25.00,
        CURRENCYCODE      => 'GBP',
        PAYMENTACTION     => 'Sale',
        RETURNURL         => "http://returnurl.tld",
        CANCELURL         => "http//cancelurl.tld",
        LANDINGPAGE       => 'Login',
        ADDOVERRIDE       => 1,
        SHIPTONAME        => "Customer Name",
        SHIPTOSTREET      => "7 Customer Street", 
        SHIPTOSTREET2     => "", 
        SHIPTOCITY        => "Town", 
        SHIPTOZIP         => "Postcode", 
        SHIPTOEMAIL       => "customer\@example.com", 
        SHIPTOCOUNTRYCODE => 'GB',
    });
    
    if ($res->success) {
        # timestamps turned into DateTime objects
        say "Response received at "
            . $res->timestamp->dmy . " "
            . $res->timestamp->hms(':');

        say $res->token;

        for my $arg ($res->args) {
            if ($res->has_arg($arg)) {
                say "$arg => " . $res->$arg;
            }
        }

        # get a redirect uri to paypal express checkout
        # the Response object will automatically detect if you have 
        # live or sandbox and return the appropriate url for you
        if (my $redirect_user_to = $res->express_checkout_uri) {
            $web_framework->redirect( $redirect_user_to );
        }
    }
    else {
        say $_
          for @{$res->errors};
    }

=head1 ATTRIBUTES

Upon creating an instance of WebService::PayPal::NVP, 3 attributes are mandatory, and there's a few you can set yourself

=head2 Mandatory

=head3 user

Your PayPal username

=head3 pass

PayPal API password

=head3 sig

PayPal API signature

=head2 Optional

=head3 url

You might not need this, but if for some reason the URL for PayPal's NVP service changes and I can't update in time, you can set it yourself.

=head3 branch

By default, this will be set to sandbox. Once you want to go live, set the branch to 'live'. 
It will also be sandbox unless you specify otherwise for obvious reasons..

=head3 api_ver

You can change the API version, but I'd recommend you leave it as this module was made for the version that is currently set!

=head3 ua

This attribute allows you to provide your own UserAgent.  This object must be of
the L<LWP::UserAgent> family, so L<WWW::Mechanize> modules will also work.

  my $nvp = WebService::PayPal::NVP->new( ua => LWP::UserAgent->new(...) );

=head1 METHODS

Please see the role L<WebService::PayPal::NVP::Requests> for available PalPal methods

=head1 TESTING

The main test will not work out of the box, because obviously it needs some sandbox/live api details before it can proceed. Simply create an C<auth.yml> file in the distribution directory with the following details:

    ---
    user: 'api_user'
    pass: 'api password'
    sig:  'api signature'
    branch: 'sandbox or live'

If it detects the file missing completely it will just skip every test. Otherwise, it will only fail if any of the required information is missing.

=head1 AUTHOR

Brad Haywood <brad@geeksware.com>

=head1 CREDITS

A lot of this module was taken from L<Business::PayPal::NVP> by Scott Wiersdorf. 
It was only rewritten in order to work properly in L<Catalyst::Model::Adaptor>.

=head2 THANKS

I'd like to thank Olaf Alders for his contributions to this project!

=head1 LICENSE

You may distribute this code under the same terms as Perl itself.

=cut
