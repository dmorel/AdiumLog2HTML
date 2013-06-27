#!/usr/bin/env perl

=head1 NAME

adium_logs_2_html.pl

=head1 VERSION

version 0.01

=head1 SYNOPSIS

Parse Adium logfiles and turn them to HTML tables.

  adium_logs_2_html > adium_logfile.html

=head1 OPTIONS

Options are passed on the command line, see an example below.

=over 4

=item C<--account>

The account, usually of the form C<(Jabber|IRC|Twitter|GTalk|).user@service.tld>.

=item C<--exclude>

Regular expression used for excluding certain conversations (usually the
other party's login name, or the chatroom name for a group chat).

=item C<--fromdate>

Start date for selecting the logs to parse, in any format Date::Parse can
understand. Optional, defaults to 8 days ago.

=item C<--todate>

End date (inclusive), optional.

=item C<--user>

User name for finding the base directory. Defaults to C<$USER>.

=item C<--auser>

Adium user name, as seen in the "Login as user" box one sometimes sees at program startup.

=item C<--nickhighlight-->

Regex to match nicknames, which will be highlighted

=item C<--help>

Print this documentation.

=back

=head1 DESCRIPTION

Transform Adium logfiles into a single HTML file, with 1 table per
conversation, sorted by account and date, and prints it to STDOUT. Makes
reading the logs possible (contrary to the built-in logfile viewer, IMHO).

Here's an example:

    ./adium_logs_2_html.pl
        --account Jabber.+booking \
        --exclude 'conference|live' \
        --from '2011-07-01' \
        --user david \
        --auser 'David Morel'
            > ~/tmp/jabber_logs.html

And an example of the full path to a logfile on my machine:

    /Users
     /david
      /Library
       /Application Support
        /Adium 2.0
         /Users
          /David Morel
           /Logs
            /Jabber.david.morel@jabber.booking.com
             /john.doe@jabber.booking.com
              /john.doe@jabber.booking.com (2011-03-29T14.40.23+0200).chatlog
               /john.doe@jabber.booking.com (2011-03-29T14.40.23+0200).xml

=head1 AUTHOR

David Morel <david dot morel at amakuru dot net>

=head1 COPYRIGHT AND LICENSE

This software is copyright (c) 2011 by David Morel.

This is free software; you can redistribute it and/or modify it under
the same terms as the Perl 5 programming language system itself.

=cut

use strict;
use warnings;

use CGI::Pretty qw(TR td th caption table h1 h2);
use Date::Parse;
use DateTime;
use Getopt::Long;
use HTML::Entities qw(encode_entities);
use Path::Class;
use Text::CSV_XS;
use XML::LibXML;
use Pod::Usage;
use Digest::SHA qw(sha1_hex);
use Data::Dumper;

my $user = $ENV{USER};
my ( $adium_user, $log_dir, $fromdate, $todate, $exclude_pattern, $help, $nickhighlight );
my $account_pattern = '.+';

GetOptions(
    "user=s" => \$user,    # unix user name for finding the basedir
    "auser=s" =>
        \$adium_user,      # not mandatory, if there is only 1 user in Adium's Users directory
    "account=s"  => \$account_pattern,    # regex pattern for account(s) to parse, eg. ''
    "fromdate=s" => \$fromdate,           # Any format parseable by Date::Parse
    "todate=s"   => \$todate,             # Any format parseable by Date::Parse
    "exclude=s"  => \$exclude_pattern,    # filenames to exclude, eg. 'conference'
    "h|help"     => \$help,
    "nickhighlight=s" =>
        \$nickhighlight,    # regex for recognizing oneself against nicknames (for highlighting)
);

pod2usage(-verbose => 2) if ($help);

$fromdate = str2time($fromdate)           # make that an epoch
    if $fromdate;
$todate = str2time($todate) + 86399       # make that an epoch, add 1 day for inclusion
    if $todate;
$fromdate ||= time - 86400 * 8;           # default 8 days in the past
$todate   ||= time;

my $users_dir = dir( '/Users', $user, 'Library/Application Support/Adium 2.0/Users/' );

# Try and find a workable logs directory
if ( !$adium_user ) {
    my @users_dirs = $users_dir->children( no_hidden => 1 );
    if ( @users_dirs == 1 && $users_dirs[0]->is_dir() ) {
        $adium_user = $users_dirs[0]->basename;
    }
    else {
        die "More than one Adium user, or no user in logs directory.\n"
            . "Please have a look and/or use the --auser option. I found these:\n\t"
            . join( "\n\t", map { $_->basename } @users_dirs ) . "\n";
    }
}

die "Cannot find specified user directory in $users_dir\n"
    if !( $log_dir = $users_dir->subdir("$adium_user/Logs") );
my @accounts = $log_dir->children();

binmode STDOUT, ':encoding(UTF-8)';

print STDOUT <<HTML;
<html>
<head>
<meta http-equiv="Content-Type" content="text/html; charset=utf-8" />
<style>
    h1 {
        text-align: left;
        margin-bottom: 10px;
        font: italic bold 15px "Lucida Grande", Lucida, Verdana, sans-serif;
        color: lightgrey;
        padding: 3px;
    }

    h2 {
        text-align: left;
        width: 100%;
        margin-bottom: 10px;
        font: bold 14px "Lucida Grande", Lucida, Verdana, sans-serif;
        color: #3560ac;
        padding: 3px;
    }

    caption {
        text-align: center;
        width: 100%;
        margin-bottom: 10px;
        font: italic bold 13px "Lucida Grande", Lucida, Verdana, sans-serif;
        color: #3560ac;
        background-color: #fff49d;
        padding: 3px;
    }

    table.msg_table {
        margin-bottom: 20px;
        width: 100%;
    }
    .msg_table tr {
        font: 12px "Lucida Grande", Lucida, Verdana, sans-serif;
    }

    .msg_table td, .msg_table th {
        border-bottom: 1px solid #eee;
        border-collapse: collapse;
        padding-right: 20px;
    }

    .date, .alias {
        width: 1%;
        white-space: nowrap;
    }

    .nickhighlight {
        color: red;
    }
</style>

    <link rel="stylesheet" href="http://code.jquery.com/ui/1.9.1/themes/base/jquery-ui.css" type="text/css" media="all" />
    <link rel="stylesheet" href="http://static.jquery.com/ui/css/demo-docs-theme/ui.theme.css" type="text/css" media="all" />
    <script src="http://ajax.googleapis.com/ajax/libs/jquery/1.9.1/jquery.min.js" type="text/javascript"></script>
    <script src="http://code.jquery.com/ui/1.10.1/jquery-ui.min.js" type="text/javascript"></script>

</head>
<body>
HTML

my $logs_data;

for my $account (@accounts) {
    next if ( $account->basename !~ /$account_pattern/ || !$account->is_dir );
    print h1( "Adium logs for user: $adium_user, account: " . $account->basename );
    undef $logs_data;
    print "<div class='accordion'>\n";
    $account->recurse( callback => \&_parse_file );    # à la File::Find

    for my $send_date ( sort keys %$logs_data ) {
        print h2('<a href="#">Logs for date: ' . $send_date . '</a>');
        print "<div>\n";
        for my $sender ( sort keys %{ $logs_data->{$send_date} } ) {
            print table (
                {   -border      => '0',
                    -width       => '100%',
                    -cellspacing => '0',
                    -class       => 'msg_table'
                },
                caption( $logs_data->{$send_date}{$sender}{caption} ),
                TR( { -align => 'LEFT', -valign => 'TOP' },
                    th( [ 'Time', 'From', 'Message' ] )
                ),
                map {
                    TR( td( { -class => 'date' }, $_->[0] ),
                        td( {   -class => 'alias'
                                    . ( $_->[1] =~ /$nickhighlight/ ? ' nickhighlight' : '' )
                            },
                            $_->[1]
                        ),
                        td( $_->[2] ),
                        )
                    } @{ $logs_data->{$send_date}{$sender}{msgs} },
            );
        }
        print "</div>\n";
    }
    print "</div>\n";
}

print <<'HTML';
<script>
    $(function() { $( ".accordion" ).accordion({ autoHeight: false, navigation: false, collapsible: true }); });
</script>

</body>
</html>
HTML

my %seen; # prevent duplicates.

sub _parse_file {
    my $file = shift;
    return if $file !~ /.xml$/;
    return if $exclude_pattern && $file->basename =~ /$exclude_pattern/;
    my $mtime = DateTime->from_epoch( epoch => $file->stat->mtime );
    return if ( $file->stat->mtime < $fromdate );

    my $xml = XML::LibXML->new(recover => 1)->parse_file($file)->documentElement
        or return;

    # Example message:
    # <message sender="john.doe@jabber.booking.com" time="2011-03-29T14:40:23+02:00" alias="John Doe">
    #    <div><span style="font-family: Helvetica; font-size: 12pt;">hi David</span></div>
    # </message>
    my @nodes = $xml->getElementsByTagName('message')
        or return;
    my ( $first_sent, @rows );
    ( my $sender = $file->basename ) =~ s/^(.+?)\s.*/$1/;
    for my $node (@nodes) {
        my $alias = $node->getAttribute('alias');
        my $sent  = str2time( $node->getAttribute('time') );
        next if ( $sent < $fromdate || $sent > $todate );
        $sent = DateTime->from_epoch( epoch => $sent )->strftime('%Y-%m-%d %H:%M:%S');
        $first_sent ||= $sent;    # keep the date for the header
        my $msg = encode_entities($node->textContent);
        my $sha1_msg = sha1_hex(Dumper([$alias, $msg]));
        push @{ $logs_data->{ substr( $sent, 0, 10 ) }{$sender}{msgs} }, [ $sent, $alias, $msg ]
            if !$seen{$sha1_msg};
        $seen{ $sha1_msg }++;

        # First sent can differ from sent, keep both
        $logs_data->{ substr( $sent, 0, 10 ) }{$sender}{caption}
            ||= "Discussion with $sender on $sent (started on $first_sent)<br /><i>file: "
            . $file->basename
            . " last-modified: "
            . $mtime->strftime('%Y-%m-%d') . ")</i>";
    }
    return 1;
}

__END__



