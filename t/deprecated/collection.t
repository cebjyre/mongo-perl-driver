#
#  Copyright 2009-2013 MongoDB, Inc.
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

# Adapted from t/collection.t to keep testing deprecated APIs

use strict;
use warnings;
use Test::More 0.96;
use Test::Fatal;
use Test::Warn;
use Test::Deep qw/!blessed/;

use utf8;
use Tie::IxHash;
use Encode qw(encode decode);
use MongoDB::Timestamp; # needed if db is being run as master
use MongoDB::Error;
use MongoDB::Code;

use MongoDB;

use lib "t/lib";
use MongoDBTest qw/build_client get_test_db server_version server_type/;

my $conn = build_client();
my $testdb = get_test_db($conn);
my $server_version = server_version($conn);
my $server_type = server_type($conn);
my $coll = $testdb->get_collection('test_collection');
my $id;
my $obj;
my $ok;
my $cursor;
my $tied;


# get_collection
subtest get_collection => sub {
    my ( $db, $c );

    ok( $c = $testdb->get_collection('foo'), "get_collection(NAME)" );
    isa_ok( $c, 'MongoDB::Collection' );
    is( $c->name, 'foo', 'get name' );

    my $wc = MongoDB::WriteConcern->new( w => 2 );

    ok( $c = $testdb->get_collection( 'foo', { write_concern => $wc } ),
        "get_collection(NAME, OPTION) (wc)" );
    is( $c->write_concern->w, 2, "coll-level write concern as expected" );

    ok( $c = $testdb->get_collection( 'foo', { write_concern => { w => 3 } } ),
        "get_collection(NAME, OPTION) (wc)" );
    is( $c->write_concern->w, 3, "coll-level write concern coerces" );

    my $rp = MongoDB::ReadPreference->new( mode => 'secondary' );

    ok( $c = $testdb->get_collection( 'foo', { read_preference => $rp } ),
        "get_collection(NAME, OPTION) (rp)" );
    is( $c->read_preference->mode, 'secondary', "coll-level read pref as expected" );

    ok( $c = $testdb->get_collection( 'foo', { read_preference => { mode => 'nearest' } } ),
        "get_collection(NAME, OPTION) (rp)" );
    is( $c->read_preference->mode, 'nearest', "coll-level read pref coerces" );

};

subtest get_namespace => sub {
    my $dbname = $testdb->name;
    my ( $db, $c );

    ok( $c = $conn->get_namespace("$dbname.foo"), "get_namespace(NAME)" );
    isa_ok( $c, 'MongoDB::Collection' );
    is( $c->name, 'foo', 'get name' );

    my $wc = MongoDB::WriteConcern->new( w => 2 );

    ok( $c = $conn->get_namespace( "$dbname.foo", { write_concern => $wc } ),
        "get_collection(NAME, OPTION) (wc)" );
    is( $c->write_concern->w, 2, "coll-level write concern as expected" );

    ok( $c = $conn->ns("$dbname.foo"), "ns(NAME)" );
    isa_ok( $c, 'MongoDB::Collection' );
    is( $c->name, 'foo', 'get name' );
};

# very small insert
{
    $id = $coll->insert({_id => 1});
    is($id, 1);
    my $tiny = $coll->find_one;
    is($tiny->{'_id'}, 1);

    $coll->remove;

    $id = $coll->insert({});
    isa_ok($id, 'MongoDB::OID');
    $tiny = $coll->find_one;
    is($tiny->{'_id'}, $id);

    $coll->remove;
}

# insert
{
    $id = $coll->insert({ just => 'another', perl => 'hacker' });
    is($coll->count, 1, 'count');

    $coll->update({ _id => $id }, {
        just => "an\xE4oth\0er",
        mongo => 'hacker',
        with => { a => 'reference' },
        and => [qw/an array reference/],
    });
    is($coll->count, 1);
}

# rename
{
    my $newcoll = $coll->rename('test_collection.rename');
    is($newcoll->name, 'test_collection.rename', 'rename');
    is($coll->count, 0, 'rename');
    is($newcoll->count, 1, 'rename');
    $coll = $newcoll->rename('test_collection');
    is($coll->name, 'test_collection', 'rename');
    is($coll->count, 1, 'rename');
    is($newcoll->count, 0, 'rename');
}

# count
{
    is($coll->count({ mongo => 'programmer' }), 0, 'count = 0');
    is($coll->count({ mongo => 'hacker'     }), 1, 'count = 1');
    is($coll->count({ 'with.a' => 'reference' }), 1, 'inner obj count');
}

# find_one
{
    $obj = $coll->find_one;
    is($obj->{mongo} => 'hacker', 'find_one');
    is(ref $obj->{with}, 'HASH', 'find_one type');
    is($obj->{with}->{a}, 'reference');
    is(ref $obj->{and}, 'ARRAY');
    is_deeply($obj->{and}, [qw/an array reference/]);
    ok(!exists $obj->{perl});
    is($obj->{just}, "an\xE4oth\0er");
}

# validate and remove
{
    is( exception { $coll->validate }, undef, 'validate' );

    $coll->remove($obj);
    is($coll->count, 0, 'remove() deleted everything (won\'t work on an old version of Mongo)');
}

# get_indexes
{
    $coll->drop;
    my $keys = tie(my %idx, 'Tie::IxHash');
    %idx = ('sn' => 1, 'ts' => -1);

    $coll->ensure_index($keys, {safe => 1});

    my @tied = $coll->get_indexes;
    is(scalar @tied, 2, 'num indexes');
    is($tied[1]->{'ns'}, $testdb->name . '.test_collection', 'namespace');
    is($tied[1]->{'name'}, 'sn_1_ts_-1', 'namespace');
}

{
    $coll->drop;

    $coll->insert({x => 1, y => 2, z => 3, w => 4});
    $cursor = $coll->query->fields({'y' => 1});
    $obj = $cursor->next;
    is(exists $obj->{'y'}, 1, 'y exists');
    is(exists $obj->{'_id'}, 1, '_id exists');
    is(exists $obj->{'x'}, '', 'x doesn\'t exist');
    is(exists $obj->{'z'}, '', 'z doesn\'t exist');
    is(exists $obj->{'w'}, '', 'w doesn\'t exist');
}

# batch insert
{
    $coll->drop;
    my $ids = $coll->batch_insert([{'x' => 1}, {'x' => 2}, {'x' => 3}]);
    is($coll->count, 3, 'batch_insert');
}

# sort
{
    $cursor = $coll->query->sort({'x' => 1});
    my $i = 1;
    while ($obj = $cursor->next) {
        is($obj->{'x'}, $i++);
    }
}

# find_one fields
{
    $coll->drop;
    $coll->insert({'x' => 1, 'y' => 2, 'z' => 3});
    my $yer = $coll->find_one({}, {'y' => 1});

    cmp_deeply(
        $yer,
        { _id => ignore(), y => 2 },
        "projection fields correct"
    );

    $coll->drop;
    $coll->batch_insert([{"x" => 1}, {"x" => 1}, {"x" => 1}]);
    $coll->remove( { "x" => 1 }, { just_one => 1 } );
    is ($coll->count, 2, 'remove just one');
}

# tie::ixhash for update/insert
{
    $coll->drop;
    my $hash = Tie::IxHash->new("f" => 1, "s" => 2, "fo" => 4, "t" => 3);
    $id = $coll->insert($hash);
    isa_ok($id, 'MongoDB::OID');
    $tied = $coll->find_one;
    is($tied->{'_id'}."", "$id");
    is($tied->{'f'}, 1);
    is($tied->{'s'}, 2);
    is($tied->{'fo'}, 4);
    is($tied->{'t'}, 3);

    my $criteria = Tie::IxHash->new("_id" => $id);
    $hash->Push("something" => "else");
    $coll->update($criteria, $hash);
    $tied = $coll->find_one;
    is($tied->{'f'}, 1);
    is($tied->{'something'}, 'else');
}

# () update/insert
{
    $coll->drop;
    my @h = ("f" => 1, "s" => 2, "fo" => 4, "t" => 3);
    $id = $coll->insert(\@h);
    isa_ok($id, 'MongoDB::OID');
    $tied = $coll->find_one;
    is($tied->{'_id'}."", "$id");
    is($tied->{'f'}, 1);
    is($tied->{'s'}, 2);
    is($tied->{'fo'}, 4);
    is($tied->{'t'}, 3);

    my @criteria = ("_id" => $id);
    my @newobj = ('$inc' => {"f" => 1});
    $coll->update(\@criteria, \@newobj);
    $tied = $coll->find_one;
    is($tied->{'f'}, 2);
}

# multiple update
{
    $coll->drop;
    $coll->insert({"x" => 1});
    $coll->insert({"x" => 1});

    $coll->insert({"x" => 2, "y" => 3});
    $coll->insert({"x" => 2, "y" => 4});

    $coll->update({"x" => 1}, {'$set' => {'x' => "hi"}});
    # make sure one is set, one is not
    ok($coll->find_one({"x" => "hi"}));
    ok($coll->find_one({"x" => 1}));

    my $res = $coll->update({"x" => 2}, {'$set' => {'x' => 4}}, {'multiple' => 1});
    is($coll->count({"x" => 4}), 2) or diag explain $res;

    $cursor = $coll->query({"x" => 4})->sort({"y" => 1});

    $obj = $cursor->next();
    is($obj->{'y'}, 3);
    $obj = $cursor->next();
    is($obj->{'y'}, 4);
}

# check with upsert if there are matches
subtest "multiple update" => sub {
    plan skip_all => "multiple update won't work with db version $server_version"
      unless $server_version >= v1.3.0;

    $coll->update({"x" => 4}, {'$set' => {"x" => 3}}, {'multiple' => 1, 'upsert' => 1});
    is($coll->count({"x" => 3}), 2, 'count');

    $cursor = $coll->query({"x" => 3})->sort({"y" => 1});

    $obj = $cursor->next();
    is($obj->{'y'}, 3, 'y == 3');
    $obj = $cursor->next();
    is($obj->{'y'}, 4, 'y == 4');

    # check with upsert if there are no matches
    # also check that 'multi' is allowed
    my $res = $coll->update({"x" => 15}, {'$set' => {"z" => 4}}, {'upsert' => 1, 'multi' => 1});
    ok( $res->{ok}, "update succeeded" );
    is( $res->{n}, 0, "update match count" );
    isa_ok( $res->{upserted}, "MongoDB::OID" );
    ok($coll->find_one({"z" => 4}));

    # check that 'multi' and 'multiple' conflicting is an error
    like(
        exception {
            $coll->update(
                { "x"     => 15 },
                { '$set'  => { "z" => 4 } },
                { 'multi' => 1, 'multiple' => undef }
              )
        },
        qr/can't use conflicting values/,
        "multi and multiple conflicting is an error"
    );

    is($coll->count(), 5);
};

# safe insert
{
    $coll->drop;
    $coll->insert({_id => 1}, {safe => 1});
    my $err = exception { $coll->insert({_id => 1}, {safe => 1}) };
    ok( $err, "got error" );
    isa_ok( $err, 'MongoDB::DatabaseError', "duplicate insert error" );
    like( $err->message, qr/duplicate key/, 'error was duplicate key exception')
}

# safe update
{
    $coll->drop;
    $coll->ensure_index({name => 1}, {unique => 1});
    $coll->insert( {name => 'Alice'} );
    $coll->insert( {name => 'Bob'} );

    my $err = exception { $coll->update( { name => 'Alice'}, { '$set' => { name => 'Bob' } }, { safe => 0 } ) };
    is($err, undef, "bad update with safe => 0: no error");

    for my $h ( {}, { safe => 1 } ) {
        my $res;
        $err = exception { $res = $coll->update( { name => 'Alice'}, { '$set' => { name => 'Bob' } }, $h ) };
        my $case = $h ? "explicit" : "default";
        ok( $err, "bad update with $case safe gives error" ) or diag explain $res;
        like( $err->message, qr/duplicate key/, 'error was duplicate key exception');
        ok( my $ok = $coll->update( { name => 'Alice' }, { '$set' => { age => 23 } }, $h ), "did legal update" );
        isa_ok( $ok, "HASH" );
        is( $ok->{n}, 1, "n set to 1" );
        ok( $ok->{ok}, "legal update with $case safe had no error" );
    }
}

# save
{
    $coll->drop;

    my $x = {"hello" => "world"};
    $coll->save($x);
    is($coll->count, 1, 'save');

    my $y = $coll->find_one;
    $y->{"hello"} = 3;
    $coll->save($y);
    is($coll->count, 1);

    my $z = $coll->find_one;
    is($z->{"hello"}, 3);
}

# find
{
    $coll->drop;

    $coll->insert({x => 1});
    $coll->insert({x => 4});
    $coll->insert({x => 5});
    $coll->insert({x => 1, y => 2});

    $cursor = $coll->find({x=>4});
    my $result = $cursor->next;
    is($result->{'x'}, 4, 'find');

    $cursor = $coll->find({x=>{'$gt' => 1}})->sort({x => -1});
    $result = $cursor->next;
    is($result->{'x'}, 5);
    $result = $cursor->next;
    is($result->{'x'}, 4);

    $cursor = $coll->find({y=>2})->fields({y => 1, _id => 0});
    $result = $cursor->next;
    is(keys %$result, 1, 'find fields');
}

# findAndModify
{
    $coll->insert( { name => "find_and_modify_test", value => 42 } );
    $coll->find_and_modify( { query => { name => "find_and_modify_test" }, update => { '$set' => { value => 43 } } } );
    my $doc = $coll->find_one( { name => "find_and_modify_test" } );
    is( $doc->{value}, 43 );

    $coll->drop;

    $coll->insert( { name => "find_and_modify_test", value => 46 } );
    my $new = $coll->find_and_modify( { query  => { name => "find_and_modify_test" },
                                        update => { '$set' => { value => 57 } },
                                        new    => 1 } );

    is ( $new->{value}, 57 );

    $coll->drop;

    my $nothing = $coll->find_and_modify( { query => { name => "does not exist" }, update => { name => "barf" } } );

    is ( $nothing, undef );

    $coll->drop;
}

# aggregate
subtest "aggregation" => sub {
    plan skip_all => "Aggregation framework unsupported on MongoDB $server_version"
        unless $server_version >= v2.2.0;

    $coll->batch_insert( [ { wanted => 1, score => 56 },
                           { wanted => 1, score => 72 },
                           { wanted => 1, score => 96 },
                           { wanted => 1, score => 32 },
                           { wanted => 1, score => 61 },
                           { wanted => 1, score => 33 },
                           { wanted => 0, score => 1000 } ] );

    my $cursor = $coll->aggregate( [ { '$match'   => { wanted => 1 } },
                                  { '$group'   => { _id => 1, 'avgScore' => { '$avg' => '$score' } } } ] );

    isa_ok( $cursor, 'MongoDB::QueryResult' );
    my $res = [ $cursor->all ];
    ok $res->[0]{avgScore} < 59;
    ok $res->[0]{avgScore} > 57;

    if ( $server_version < v2.5.0 ) {
        is(
            exception { $coll->aggregate( [ {'$match' => { count => {'$gt' => 0} } } ], { cursor => {} } ) },
            undef,
            "asking for cursor when unsupported does not throw error"
        );
    }
};

# aggregation cursors
subtest "aggregation cursors" => sub {
    plan skip_all => "Aggregation cursors unsupported on MongoDB $server_version"
        unless $server_version >= v2.5.0;

    for( 1..20 ) {
        $coll->insert( { count => $_ } );
    }

    $cursor = $coll->aggregate( [ { '$match' => { count => { '$gt' => 0 } } } ], { cursor => 1 } );

    isa_ok $cursor, 'MongoDB::QueryResult';
    is $cursor->started_iterating, 1;
    is( ref( $cursor->_docs ), ref [ ] );
    is $cursor->_doc_count, 20, "document count cached in cursor";

    for( 1..20 ) {
        my $doc = $cursor->next;
        is( ref( $doc ), ref { } );
        is $doc->{count}, $_;
        is $cursor->_doc_count, ( 20 - $_ );
    }

    # make sure we can transition to a "real" cursor
    $cursor = $coll->aggregate( [ { '$match' => { count => { '$gt' => 0 } } } ], { cursor => { batchSize => 10 } } );

    isa_ok $cursor, 'MongoDB::QueryResult';
    is $cursor->started_iterating, 1;
    is( ref( $cursor->_docs), ref [ ] );
    is $cursor->_doc_count, 10, "doc count correct";

    for( 1..20 ) {
        my $doc = $cursor->next;
        isa_ok( $doc, 'HASH' );
        is $doc->{count}, $_, "doc count field is $_";
    }

    $coll->drop;
};

# aggregation $out
subtest "aggregation \$out" => sub {
    plan skip_all => "Aggregation result collections unsupported on MongoDB $server_version"
        unless $server_version >= v2.5.0;

    for( 1..20 ) {
        $coll->insert( { count => $_ } );
    }

    my $result = $coll->aggregate( [ { '$match' => { count => { '$gt' => 0 } } }, { '$out' => 'test_out' } ] );

    ok $result;
    my $res_coll = $testdb->get_collection( 'test_out' );
    my $cursor = $res_coll->find;

    for( 1..20 ) {
        my $doc = $cursor->next;
        is( ref( $doc ), ref { } );
        is $doc->{count}, $_;
    }

    $res_coll->drop;
    $coll->drop;
};

# aggregation explain
subtest "aggregation explain" => sub {
    plan skip_all => "Aggregation explain unsupported on MongoDB $server_version"
        unless $server_version >= v2.4.0;

    for ( 1..20 ) {
        $coll->insert( { count => $_ } );
    }

    my $cursor = $coll->aggregate( [ { '$match' => { count => { '$gt' => 0 } } }, { '$sort' => { count => 1 } } ],
                                   { explain => 1 } );

    my $result = $cursor->next;

    is( ref( $result ), 'HASH', "aggregate with explain returns a hashref" );

    my $expected = $server_version >= v2.6.0 ? 'stages' : 'serverPipeline';

    ok( exists $result->{$expected}, "result had '$expected' field" )
        or diag explain $result;

    $coll->drop;
};

subtest "deep update" => sub {
    $coll->drop;
    $coll->insert( { _id => 1 } );

    $coll->update( { _id => 1 }, { '$set' => { 'x.y' => 42 } } );

    my $doc = $coll->find_one( { _id => 1 } );
    is( $doc->{x}{y}, 42, "deep update worked" );

    like(
        exception { $coll->update( { _id => 1 }, { 'p.q' => 23 } ) },
        qr/documents for storage cannot contain/,
        "replace with dots in field dies"
    );

};

subtest "count w/ hint" => sub {

    $coll->drop;
    $coll->insert( { i => 1 } );
    $coll->insert( { i => 2 } );
    is ($coll->count(), 2, 'count = 2');

    $coll->ensure_index( { i => 1 } );

    is( $coll->count( { i => 1 }, { hint => '_id_' } ), 1, 'count w/ hint & spec');
    is( $coll->count( {}, { hint => '_id_' } ), 2, 'count w/ hint');

    my $current_version = version->parse($server_version);
    my $version_2_6 = version->parse('v2.6');

    if ( $current_version > $version_2_6 ) {

        eval { $coll->count( { i => 1 } , { hint => 'BAD HINT' } ) };
        like($@, ($server_type eq "Mongos" ? qr/failed/ : qr/bad hint/ ), 'check bad hint error');

    } else {

        is( $coll->count( { i => 1 } , { hint => 'BAD HINT' } ), 1, 'bad hint and spec');
    }

    $coll->ensure_index( { x => 1 }, { sparse => 1 } );

    if ($current_version > $version_2_6 ) {

        is( $coll->count( {  i => 1 } , { hint => 'x_1' } ), 0, 'spec & hint on empty sparse index');

    } else {

        is( $coll->count( {  i => 1 } , { hint => 'x_1' } ), 1, 'spec & hint on empty sparse index');
    }

    is( $coll->count( {}, { hint => 'x_1' } ), 2, 'hint on empty sparse index');
};

my $js_str = 'function() { return this.a > this.b }';
my $js_obj = MongoDB::Code->new( code => $js_str );

for my $criteria ( $js_str, $js_obj ) {
    my $type = ref($criteria) || 'string';
    subtest "query with \$where as $type" => sub {
        $coll->drop;
        $coll->insert( { a => 1, b => 1, n => 1 } );
        $coll->insert( { a => 2, b => 1, n => 2 } );
        $coll->insert( { a => 3, b => 1, n => 3 } );
        $coll->insert( { a => 0, b => 1, n => 4 } );
        $coll->insert( { a => 1, b => 2, n => 5 } );
        $coll->insert( { a => 2, b => 3, n => 6 } );

        my @docs = $coll->find( { '$where' => $criteria } )->sort( { n => 1 } )->all;
        is( scalar @docs, 2, "correct count a > b" )
          or diag explain @docs;
        cmp_deeply(
            \@docs,
            [
                { _id => ignore(), a => 2, b => 1, n => 2 },
                { _id => ignore(), a => 3, b => 1, n => 3 }
            ],
            "javascript query correct"
        );
    };
}

done_testing;
