# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this
# file, You can obtain one at http://mozilla.org/MPL/2.0/.
#
# This Source Code Form is "Incompatible With Secondary Licenses", as
# defined by the Mozilla Public License, v. 2.0.

package Bugzilla::Extension::PhabBugz::WebService;

use 5.10.1;
use strict;
use warnings;

use base qw(Bugzilla::WebService);

use Bugzilla::Constants;
use Bugzilla::User;
use Bugzilla::Util qw(datetime_from time_ago);
use Bugzilla::WebService::Constants;

use Bugzilla::Extension::PhabBugz::Constants;
use Bugzilla::Extension::PhabBugz::Util qw(
    add_security_sync_comments
    create_revision_attachment
    get_bug_role_phids
    get_needs_review
    get_security_sync_groups
    intersect
    is_attachment_phab_revision
    request
);

use DateTime ();
use List::Util qw(first uniq);
use List::MoreUtils qw(any);
use MIME::Base64 qw(decode_base64);

use constant READ_ONLY => qw(
    check_user_permission_for_bug
    needs_review
);

use constant PUBLIC_METHODS => qw(
    check_user_permission_for_bug
    needs_review
);

sub check_user_permission_for_bug {
    my ($self, $params) = @_;

    my $user = Bugzilla->login(LOGIN_REQUIRED);

    # Ensure PhabBugz is on
    ThrowUserError('phabricator_not_enabled')
        unless Bugzilla->params->{phabricator_enabled};

    # Validate that the requesting user's email matches phab-bot
    ThrowUserError('phabricator_unauthorized_user')
        unless $user->login eq PHAB_AUTOMATION_USER;

    # Validate that a bug id and user id are provided
    ThrowUserError('phabricator_invalid_request_params')
        unless ($params->{bug_id} && $params->{user_id});

    # Validate that the user and bug exist
    my $target_user = Bugzilla::User->check({ id => $params->{user_id}, cache => 1 });

    # Send back an object which says { "result": 1|0 }
    return {
        result => $target_user->can_see_bug($params->{bug_id})
    };
}

sub needs_review {
    my ($self, $params) = @_;
    ThrowUserError('phabricator_not_enabled')
        unless Bugzilla->params->{phabricator_enabled};
    my $user = Bugzilla->login(LOGIN_REQUIRED);
    my $dbh  = Bugzilla->dbh;

    my $reviews = get_needs_review();

    my $authors = Bugzilla::Extension::PhabBugz::User->match({
        phids => [
            uniq
            grep { defined }
            map { $_->{fields}{authorPHID} }
            @$reviews
        ]
    });

    my %author_phab_to_id = map { $_->phid => $_->bugzilla_user->id } @$authors;
    my %author_id_to_user = map { $_->bugzilla_user->id => $_->bugzilla_user } @$authors;

    # bug data
    my $visible_bugs = $user->visible_bugs([
        uniq
        grep { $_ }
        map { $_->{fields}{'bugzilla.bug-id'} }
        @$reviews
    ]);

    # get all bug statuses and summaries in a single query to avoid creation of
    # many bug objects
    my %bugs;
    if (@$visible_bugs) {
        #<<<
        my $bug_rows =$dbh->selectall_arrayref(
            'SELECT bug_id, bug_status, short_desc ' .
            '  FROM bugs ' .
            ' WHERE bug_id IN (' . join(',', ('?') x @$visible_bugs) . ')',
            { Slice => {} },
            @$visible_bugs
        );
        #>>>
        %bugs = map { $_->{bug_id} => $_ } @$bug_rows;
    }

    # build result
    my $datetime_now = DateTime->now(time_zone => $user->timezone);
    my @result;
    foreach my $review (@$reviews) {
        my $review_flat = {
            id     => $review->{id},
            status => $review->{fields}{review_status},
            title  => $review->{fields}{title},
            url    => Bugzilla->params->{phabricator_base_uri} . 'D' . $review->{id},
        };

        # show date in user's timezone
        my $datetime = DateTime->from_epoch(
            epoch     => $review->{fields}{dateModified},
            time_zone => 'UTC'
        );
        $datetime->set_time_zone($user->timezone);
        $review_flat->{updated}       = $datetime->strftime('%Y-%m-%d %T %Z');
        $review_flat->{updated_fancy} = time_ago($datetime, $datetime_now);

        # review requester
        if (my $author = $author_id_to_user{$author_phab_to_id{ $review->{fields}{authorPHID} }}) {
            $review_flat->{author_name}  = $author->name;
            $review_flat->{author_email} = $author->email;
        }
        else {
            $review_flat->{author_name}  = 'anonymous';
            $review_flat->{author_email} = 'anonymous';
        }

        # referenced bug
        if (my $bug_id = $review->{fields}{'bugzilla.bug-id'}) {
            my $bug = $bugs{$bug_id};
            $review_flat->{bug_id}      = $bug_id;
            $review_flat->{bug_status}  = $bug->{bug_status};
            $review_flat->{bug_summary} = $bug->{short_desc};
        }

        push @result, $review_flat;
    }

    return { result => \@result };
}

sub rest_resources {
    return [
        # Bug permission checks
        qr{^/phabbugz/check_bug/(\d+)/(\d+)$}, {
            GET => {
                method => 'check_user_permission_for_bug',
                params => sub {
                    return { bug_id => $_[0], user_id => $_[1] };
                }
            }
        },
        # Review requests
        qw{^/phabbugz/needs_review$}, {
            GET => {
                method => 'needs_review',
            },
        },
    ];
}

1;
