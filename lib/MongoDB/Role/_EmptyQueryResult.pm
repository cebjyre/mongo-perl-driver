#
#  Copyright 2014 MongoDB, Inc.
#
#  Licensed under the Apache License, Version 2.0 (the "License");
#  you may not use this file except in compliance with the License.
#  You may obtain a copy of the License at
#
#  http://www.apache.org/licenses/LICENSE-2.0
#
#  Unless required by applicable law or agreed to in writing, software
#  distributed under the License is distributed on an "AS IS" BASIS,
#  WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
#  See the License for the specific language governing permissions and
#  limitations under the License.
#

package MongoDB::Role::_EmptyQueryResult;

# MongoDB interface for generating an empty query result

use version;
our $VERSION = 'v0.999.998.5'; # TRIAL

use MongoDB::QueryResult;
use Moose::Role;
use namespace::clean -except => 'meta';

requires 'client';

sub _empty_query_result {
    my ( $self, $link ) = @_;

    my $qr = MongoDB::QueryResult->new(
        _client => $self->client,
        address => $link->address,
        cursor  => {
            ns         => '',
            id         => 0,
            firstBatch => [],
        },
    );
}

1;
