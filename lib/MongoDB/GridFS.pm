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

package MongoDB::GridFS;


# ABSTRACT: A file storage utility

use version;
our $VERSION = 'v0.999.998.5'; # TRIAL

use MongoDB::GridFS::File;
use DateTime 0.78; # drops dependency on bug-prone Math::Round
use Digest::MD5;
use Moose;
use MongoDB::WriteConcern;
use MongoDB::_Types -types;
use Types::Standard -types;
use namespace::clean -except => 'meta';

=attr chunk_size

The number of bytes per chunk.  Defaults to 261120 (255kb).

=cut

$MongoDB::GridFS::chunk_size = 261120;

has _database => (
    is       => 'ro',
    isa      => InstanceOf['MongoDB::Database'],
    required => 1,
);

=attr read_preference

A L<MongoDB::ReadPreference> object.  It may be initialized with a string
corresponding to one of the valid read preference modes or a hash reference
that will be coerced into a new MongoDB::ReadPreference object.
By default it will be inherited from a L<MongoDB::Database> object.

=cut

has read_preference => (
    is       => 'ro',
    isa      => ReadPreference,
    required => 1,
    coerce   => 1,
);

=attr write_concern

A L<MongoDB::WriteConcern> object.  It may be initialized with a hash
reference that will be coerced into a new MongoDB::WriteConcern object.
By default it will be inherited from a L<MongoDB::Database> object.

=cut

has write_concern => (
    is       => 'ro',
    isa      => WriteConcern,
    required => 1,
    coerce   => 1,
);

=attr prefix

The prefix used for the collections.  Defaults to "fs".

=cut

has prefix => (
    is      => 'ro',
    isa     => Str,
    default => 'fs'
);

has files => (
    is => 'ro',
    isa => InstanceOf['MongoDB::Collection'],
    lazy_build => 1
);

sub _build_files {
    my $self = shift;
    my $coll = $self->_database->get_collection(
        $self->prefix . '.files',
        {
            read_preference => $self->read_preference,
            write_concern   => $self->write_concern
        }
    );
    return $coll;
}

has chunks => (
    is => 'ro',
    isa => InstanceOf['MongoDB::Collection'],
    lazy_build => 1
);

sub _build_chunks {
    my $self = shift;
    my $coll = $self->_database->get_collection(
        $self->prefix . '.chunks',
        {
            read_preference => $self->read_preference,
            write_concern   => $self->write_concern
        }
    );
    return $coll;
}

# This checks if the required indexes for GridFS exist in for the current database.
# If they are not found, they will be created.
sub BUILD {
    my ($self) = @_;
    $self->_ensure_indexes();
    return;
}


sub _ensure_indexes {
    my ($self) = @_;

    # ensure the necessary index is present (this may be first usage)
    $self->files->ensure_index(Tie::IxHash->new(filename => 1), {"safe" => 1});
    $self->chunks->ensure_index(Tie::IxHash->new(files_id => 1, n => 1), {"safe" => 1, "unique" => 1});
}

=method get

    $file = $grid->get($id);

Get a file from GridFS based on its _id.  Returns a L<MongoDB::GridFS::File>.

To retrieve a file based on metadata like C<filename>, use the L</find_one>
method instead.

=cut

sub get {
    my ($self, $id) = @_;

    return $self->find_one({_id => $id});
}

=method put

    $id = $grid->put($fh, $metadata);
    $id = $grid->put($fh, {filename => "pic.jpg"});

Inserts a file into GridFS, adding a L<MongoDB::OID> as the _id field if the
field is not already defined.  This is a wrapper for C<MongoDB::GridFS::insert>,
see that method below for more information.

Returns the _id field.

=cut

sub put {
    my ($self, $fh, $metadata) = @_;

    return $self->insert($fh, $metadata, {safe => 1});
}

=method delete

    $grid->delete($id)

Removes the file with the given _id.  Will die if the remove is unsuccessful.
Does not return anything on success.

=cut

sub delete {
    my ($self, $id) = @_;

    $self->remove({_id => $id}, {safe => 1});
}

=method find_one

    $file = $grid->find_one({"filename" => "foo.txt"});
    $file = $grid->find_one($criteria, $fields);

Returns a matching MongoDB::GridFS::File or undef.

=cut

sub find_one {
    my ($self, $criteria, $fields) = @_;
    $criteria ||= {};

    my $file = $self->files->find_one($criteria, $fields);
    return undef unless $file;
    return MongoDB::GridFS::File->new({_grid => $self,info => $file});
}

=method remove

    $grid->remove({"filename" => "foo.txt"});
    $grid->remove({"filename" => "foo.txt"}, $options);

Cleanly removes files from the database.  C<$options> is a hash of options for
the remove.

A hashref of options may be provided with the following keys:

=for :list
* C<just_one>: If true, only one file matching the criteria will be removed.
* C<safe>: (DEPRECATED) If true, each remove will be checked for success and
  die on failure.  Set the L</write_concern> attribute instead.

This method doesn't return anything.

=cut

sub remove {
    my ( $self, $criteria, $options ) = @_;
    $options ||= {};

    my $chunks =
      exists $options->{safe}
      ? $self->chunks->clone( write_concern => $self->_dynamic_write_concern($options) )
      : $self->chunks;

    my $files =
      exists $options->{safe}
      ? $self->files->clone( write_concern => $self->_dynamic_write_concern($options) )
      : $self->files;

    if ( $options->{just_one} ) {
        my $meta = $files->find_one($criteria);
        $chunks->delete_many( { "files_id" => $meta->{'_id'} } );
        $files->delete_one( { "_id" => $meta->{'_id'} } );
    }
    else {
        my $cursor = $files->find($criteria);
        while ( my $meta = $cursor->next ) {
            $chunks->delete_many( { "files_id" => $meta->{'_id'} } );
        }
        $files->delete_many($criteria);
    }
    return;
}


=method insert

    $id = $gridfs->insert($fh);
    $id = $gridfs->insert($fh, $metadata);
    $id = $gridfs->insert($fh, $metadata, $options);

    $id = $gridfs->insert($fh, {"content-type" => "text/html"});

Reads from a file handle into the database.  Saves the file with the given
metadata.  The file handle must be readable.

A hashref of options may be provided with the following keys:

=for :list
* C<safe>: (DEPRECATED) Will do safe inserts and check the MD5 hash calculated
  by the database against an MD5 hash calculated by the local filesystem.  If
  the two hashes do not match, then the chunks already inserted will be removed
  and the program will die. Set the L</write_concern> attribute instead.

Because C<MongoDB::GridFS::insert> takes a file handle, it can be used to insert
very long strings into the database (as well as files).  C<$fh> must be a
FileHandle (not just the native file handle type), so you can insert a string
with:

    # open the string like a file
    open($basic_fh, '<', \$very_long_string);

    # turn the file handle into a FileHandle
    $fh = FileHandle->new;
    $fh->fdopen($basic_fh, 'r');

    $gridfs->insert($fh);

=cut

sub insert {
    my ($self, $fh, $metadata, $options) = @_;
    $options ||= {};

    confess "not a file handle" unless $fh;
    $metadata = {} unless $metadata && ref $metadata eq 'HASH';

    my $chunks =
      exists $options->{safe}
      ? $self->chunks->clone( write_concern => $self->_dynamic_write_concern($options) )
      : $self->chunks;

    my $files =
      exists $options->{safe}
      ? $self->files->clone( write_concern => $self->_dynamic_write_concern($options) )
      : $self->files;

    my $start_pos = $fh->getpos();

    my $id;
    if (exists $metadata->{"_id"}) {
        $id = $metadata->{"_id"};
    }
    else {
        $id = MongoDB::OID->new;
    }

    my $n = 0;
    my $length = 0;
    while ((my $len = $fh->read(my $data, $MongoDB::GridFS::chunk_size)) != 0) {
        $chunks->insert_one({"files_id" => $id,
                               "n"        => $n,
                               "data"     => bless(\$data)});
        $n++;
        $length += $len;
    }

    $fh->setpos($start_pos);

    my %copy = %{$metadata};
    # compare the md5 hashes
    if ($files->write_concern->is_safe) {
        # get an md5 hash for the file. set the retry flag to 'true' incase the 
        # database, collection, or indexes are missing. That way we can recreate them 
        # retry the md5 calc.
        my $result = $self->_calc_md5($chunks, $id, $self->prefix, 1);
        $copy{"md5"} = $result->{"md5"};

        my $md5 = Digest::MD5->new;
        $md5->addfile($fh);
        $fh->setpos($start_pos);
        my $digest = $md5->hexdigest;
        if ($digest ne $result->{md5}) {
            # cleanup and die
            $chunks->delete_many({files_id => $id});
            die "md5 hashes don't match: database got $result->{md5}, fs got $digest";
        }
    }

    $copy{"_id"} = $id;
    $copy{"chunkSize"} = $MongoDB::GridFS::chunk_size;
    $copy{"uploadDate"} = DateTime->now;
    $copy{"length"} = $length;
    return $files->insert_one(\%copy)->inserted_id;
}

# Calculates the md5 of the file on the server
# $chunks: collection object with correct write concern
# $id    : reference to the object we want to hash
# $root  : the namespace the file resides in
# $retry : a flag which controls whether or not to retry the md5 calc. 
#         (which is currently only if we are missing our indexes)
sub _calc_md5 {
    my ($self, $chunks, $id, $root, $retry) = @_;
   
    # Try to get an md5 hash for the file
    my $result = $self->_database->run_command(["filemd5", $id, "root" => $self->prefix]);
    
    # If we didn't get a hash back, it means something is wrong (probably to do with gridfs's 
    # indexes because its currently the only error that is thrown from the md5 class)
    if (ref($result) ne 'HASH') {
        # Yep, indexes are missing. If we have the $retry flag, lets create them calc the md5 again
        # but we wont pass set the $retry flag again. We don't want an infinite loop for any reason. 
        if ($retry == 1 && $result eq 'need an index on { files_id : 1 , n : 1 }'){
            $self->_ensure_indexes();
            $result = $self->_calc_md5($chunks, $id, $root, 0);
        }
        # Well, something bad is happening, so lets clean up and die. 
        else{
            $chunks->delete_many({files_id => $id});
            die "recieve an unexpected error from the server: $result";
        }
    }
    
    return $result;
}


=method drop

    $grid->drop;

Removes all files' metadata and contents.

=cut

sub drop {
    my ($self) = @_;

    $self->files->drop;
    $self->chunks->drop;
    $self->_ensure_indexes;
}

=head2 all

    @files = $grid->all;

Returns a list of the files in the database as L<MongoDB::GridFS::File>
objects.

=cut

sub all {
    my ($self) = @_;
    my @ret;

    my $cursor = $self->files->find({});
    while (my $meta = $cursor->next) {
        push @ret, MongoDB::GridFS::File->new(
            _grid => $self,
            info => $meta);
    }
    return @ret;
}

#--------------------------------------------------------------------------#
# private methods
#--------------------------------------------------------------------------#

sub _dynamic_write_concern {
    my ( $self, $opts ) = @_;

    my $wc = $self->write_concern;

    if ( !exists $opts->{safe} ) {
        return $wc;
    }
    elsif ( $opts->{safe} ) {
        return $wc->is_safe ? $wc : MongoDB::WriteConcern->new( w => 1 );
    }
    else {
        return MongoDB::WriteConcern->new( w => 0 );
    }
}

__PACKAGE__->meta->make_immutable;

1;

=head1 SYNOPSIS

    my $grid = $database->get_gridfs;
    my $fh = IO::File->new("myfile", "r");
    $grid->insert($fh, {"filename" => "mydbfile"});

=head1 DESCRIPTION

This class models a GridFS file store in a MongoDB database and provides an API
for interacting with it.

Generally, you never construct one of these directly with C<new>.  Instead, you
call C<get_gridfs> on a L<MongoDB::Database> object.

=head1 USAGE

=head2 API

There are two interfaces for GridFS: a file-system/collection-like interface
(insert, remove, drop, find_one) and a more general interface
(get, put, delete).  Their functionality is the almost identical (get, put and
delete are always safe ops, insert, remove, and find_one are optionally safe),
using one over the other is a matter of preference.

=head2 Error handling

Unless otherwise explictly documented, all methods throw exceptions if
an error occurs.  The error types are documented in L<MongoDB::Error>.

To catch and handle errors, the L<Try::Tiny> and L<Safe::Isa> modules
are recommended:

    use Try::Tiny;
    use Safe::Isa; # provides $_isa

    try {
        $grid->get( $id )
    }
    catch {
        if ( $_->$_isa("MongoDB::TimeoutError" ) {
            ...
        }
        else {
            ...
        }
    };

To retry failures automatically, consider using L<Try::Tiny::Retry>.

=head1 SEE ALSO

Core documentation on GridFS: L<http://dochub.mongodb.org/core/gridfs>.

=cut
