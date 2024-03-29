package Giddy::Collection;

# ABSTRACT: A Giddy collection.

use Any::Moose;
use namespace::autoclean;

use Carp;
use Giddy::Collection::InMemory;
use Giddy::StaticDirectory;
use Tie::IxHash;

our $VERSION = "0.013_001";
$VERSION = eval $VERSION;

has 'path' => (is => 'ro', isa => 'Str', default => '');

has 'db' => (is => 'ro', isa => 'Giddy::Database', required => 1);

has 'cached' => (is => 'ro', isa => 'Bool', lazy_build => 1);

has '_loc' => (is => 'ro', isa => 'Int', default => 0, writer => '_set_loc');

with	'Giddy::Role::DocumentLoader',
	'Giddy::Role::DocumentMatcher',
	'Giddy::Role::DocumentStorer',
	'Giddy::Role::DocumentUpdater';

=head1 NAME

Giddy::Collection - A Giddy collection.

=head1 VERSION

version 0.013_001

=head1 SYNOPSIS

	my $coll = $db->get_collection('articles');

=head1 DESCRIPTION

This class represents Giddy collections, which are directories holding documents
in the database. Collections are hierarchical in Giddy (see L<Giddy::Manual> for
more information).

You will find most of your interaction with the Giddy database are performed on
this class' objects. The class provides methods for finding documents, creating
documents, updating documents, removing documents, iterating over query results,
etc.

=head1 CONSUMES

=over

=item * L<Giddy::Role::DocumentLoader>

=item * L<Giddy::Role::DocumentMatcher>

=item * L<Giddy::Role::DocumentStorer>

=item * L<Giddy::Role::DocumentUpdater>

=back

=head1 ATTRIBUTES

=head2 path

The relative path of the collection. Defaults to the empty string (''), which is
the root directory of the database. Never has a starting slash.

=head2 db

The L<Giddy::Database> object the collection belongs to. Required.

=head2 cached

Holds a boolean value indicating whether the collection exists in the database
index (i.e. has already been staged and commited), or isn't (i.e. a new one).
Automatically calculated.

=head2 _loc

An integer representing the current location of the iterator in the results array.
Not to be used externally.

=head1 OBJECT METHODS

=head2 DOCUMENT QUERYING

=head3 find( [ \%query, \%options ] )

Searches the collection for documents that match the provided query.
If no query is given, every document in the collection will be matched. See
L<Giddy::Manual/"FINDING DOCUMENTS"> for more information on queries.

=head3 find( [ $name, \%options ] )

Searches the collection for documents (more correctly "a document")
whos name equals C<$name>. This is a shortcut for C<< find({ _name => $name }, $options) >>.

=head2 find( [ $regex, \%options ] )

Searches the collection for documents whose name matches the regular
expression provided. This is a shortcut for C<< find({ _name => qr/some_regex/ }, $options >>.

All version of the method return a L<Giddy::Collection::InMemory> object, which
inherits from this class.

Searching just by name (either for equality or with a regex) is much faster
than searching by other attributes, as Giddy isn't forced to load and deserialize
every document.

In any of the above versions of the method, if you don't provide a query, or provide
an empty string or empty hash-ref, every document in the collection will be matched.

You can also pass a hash-ref of options. Currently, only the 'skip_binary' option
is available. If provided with a true value, binary attributes of documents will
be ignored. See L<Giddy::Manual/"BINARY ATTRIBUTES"> for info on binary attributes.

=cut

sub find {
	my ($self, $query, $opts) = @_;

	croak "find() expects either a scalar, a regex or a hash-ref for the query."
		if defined $query && ref $query && ref $query ne 'HASH' && ref $query ne 'Regexp';

	croak "find() expected a hash-ref of options."
		if defined $opts && ref $opts ne 'HASH';

	$query ||= '';
	$opts ||= {};

	$query = { _name => $query } if !ref $query || ref $query eq 'Regexp';

	# stage 1: create an in-memory collection
	my $coll = Giddy::Collection::InMemory->new(
		path => $self->path,
		db => $self->db,
		_query => { find => $query, coll => $self, opts => $opts }
	);

	# we want to make finds by name equality fast, so we're not gonna
	# give the in-memory collection all documents of the current
	# collection if that is the case (but only when the current collection
	# is not an in-memory collection, queries on in-memory collections
	# will already be fast enough
	$coll->_set_documents($self->_documents)
		unless (exists $query->{_name} && (!ref $query->{_name} || (ref $query->{_name} eq 'HASH' && scalar keys %{$query->{_name}} == 1 && $query->{_name}->{'$eq'})));

	# stage 2: are we matching by name? we do if query is a scalar
	# or if the query hash-ref has the _name key
	if (exists $query->{_name}) {
		# let's find documents that match this name
		$coll->_set_documents($self->_match_by_name(delete($query->{_name}), $opts));
	}

	# stage 3: are we querying by document attributes too?
	if (scalar keys %$query) {
		my ($docs, $loaded) = $coll->_match_by_query($query, $opts);
		$coll->_set_documents($docs);
		$coll->_set_loaded($loaded);
	}

	return $coll;
}

=head3 find_one( [ $query, \%options ] )

Same as calling C<< find($query, $options)->first() >>.

=cut

sub find_one {
	shift->find(@_)->first;
}

=head3 grep( [ \@strings, \%options ] )

Finds documents whose file contents (I<including> attribute names and database YAML
structure) match all (or any, depending on C<\%options>) of the provided
strings. This is much faster than using C<find()> as it simply uses the
C<git grep> command, but is obviously less useful.

The only option supported is 'or'. If passed with a true value, documents that
have at least one of the provided strings will be matched. Otherwise only documents
that have all strings are matched.

If the strings array is empty, all documents in the collection will match.

=head3 grep( [ $string ] )

Finds documents whose file contents (I<including> attribute names and database YAML
structure) match the provided string. If string is empty, all documents in the
collection will match.

Both methods return a L<Giddy::Collection::InMemory> object.

=cut

sub grep {
	my ($self, $query, $opts) = @_;

	croak "grep() expected a hash-ref of options."
		if $opts && ref $opts ne 'HASH';

	$query ||= [];
	$query = [$query] if !ref $query;
	$opts ||= {};

	return $self->find('', $opts) unless scalar @$query;

	my $coll = Giddy::Collection::InMemory->new(
		path => $self->path,
		db => $self->db,
		_query => { grep => $query, coll => $self, opts => $opts }
	);

	my @cmd = ('grep', '-I', '--name-only', '--max-depth', 1, '--cached');
	push(@cmd, '--all-match') unless $opts->{'or'}; # that's how we do an 'and' search'

	foreach (@$query) {
		push(@cmd, '-e', $_);
	}

	push(@cmd, { cwd => $self->db->_repo->work_tree.'/'.$self->path })
		if $self->path;

	my $docs = Tie::IxHash->new;
	foreach ($self->db->_repo->run(@cmd)) {
		if (m!/!) { # there'll at most be one slash since --max-depth is 1
			my $name = $`;
			# if this is an in-memory collection, we have to ignore
			# documents in the actual filesystem collection but not here
			next unless $self->_documents->EXISTS($name);
			next if $docs->EXISTS($name);
			$docs->STORE($name => 'dir');
		} else {
			# if this is an in-memory collection, we have to ignore
			# documents in the actual filesystem collection but not here
			next unless $self->_documents->EXISTS($_);
			next if $docs->EXISTS($_);
			$docs->STORE($_ => 'file');
		}
	}

	# sort the documents alphabetically by name
	$docs->SortByKey;

	$coll->_set_documents($docs);

	return $coll;
}

=head3 grep_one( [ $string, \%options ] )

=head3 grep_one( [ \@strings, \%options ] )

Same as calling C<< grep( $string(s), $options)->first >>.

=cut

sub grep_one {
	shift->grep(@_)->first;
}

=head2 DOCUMENT MANIPULATION

=head3 insert( $name, \%attributes )

Creates a new document in the collection. You must provide a name for the document
(keep in mind that the name will be the document's file/directory's name, so try
not to use fancy characters), and a hash-ref of the document's attributes. This hash-ref
doesn't have to be flat, attributes can be nestable (i.e. they can have array and
hash references themselves).

If C<$attributes> has the '_body' key, the document created will be a document
file. Otherwise a document directory will be created. See L<Giddy::Manual/"CREATING DOCUMENTS">
for more information on documents.

Returns the path of the document created relative to the database root directory
(including a starting slash). Croaks if a document or a sub-collection named C<$name>
already exists in the collection.

=cut

sub insert {
	my ($self, $filename, $attrs) = @_;

	croak "You must provide a filename for the new document (that doesn't start with a slash)."
		unless $filename && $filename !~ m!^/!;

	return ($self->batch_insert([$filename => $attrs]))[0];
}

=head3 batch_insert( [ $name1 => \%attrs1, $name2 => \%attrs2, ... ] )

Inserts a series of documents one after another. Returns a list with the names of
all documents created. If even one document cannot be created (mostly since a similarly
named document/collection already exists), none will be created.

=cut

sub batch_insert {
	my ($self, $docs) = @_;

	# first, make sure the document array is valid
	croak "batch_insert() expects an array-ref of documents."
		unless $docs && ref $docs eq 'ARRAY';
	croak "Odd number of elements in document array, batch_insert() expects an even-numberd array."
		unless scalar @$docs % 2 == 0;

	my $hash = Tie::IxHash->new(@$docs);

	# make sure array is valid and we can actually create all the documents (i.e. they
	# don't already exist) - if even one document is invalid, we don't create any
	foreach my $filename ($hash->Keys) {
		croak "A document called $filename already exists."
			if $self->cached && $self->db->_path_exists($self->_path_to($filename));

		my $attrs = $hash->FETCH($filename);

		croak "You must provide document ${filename}'s attributes as a hash-ref."
			unless $attrs && ref $attrs eq 'HASH';
	}

	my @names; # will hold names of all documents created

	# store the documents in the filesystem
	foreach my $filename ($hash->Keys) {
		$self->_store_document($filename, $hash->FETCH($filename));

		# return the document's path
		push(@names, $filename);
	}

	return @names;
}

=head3 update( $name, \%object, [ \%options ] )

=head3 update( \%query, \%object, [ \%options ] )

Performs a query on the collection, and updates the first document found according
to the update object (C<\%object> above). You must provide a query, but this
can be an empty string or hash-ref, in which case all documents in the collection
will be matched. An options hash-ref can be provided, with any of the following options:

=over

=item * skip_binary - See L</"BINARY ATTRIBUTES"> for info.

=item * multiple - Update all documents you find, not just the first one.

=item * upsert - If you don't find any document that matches the query, create one

=back

Returns a hash-ref with two keys: 'n' - with the number of documents updated (0
if none) and 'docs' - an array-ref with the names of all documents updated (empty if none).

See L<Giddy::Manual/"UPDATING DOCUMENTS"> for more information on updating.

=cut

sub update {
	my ($self, $query, $obj, $options) = @_;

	croak "update() requires a query string (can be empty) or hash-ref (can also be empty)."
		unless defined $query;
	croak "update() requires a hash-ref object to update according to."
		unless $obj && ref $obj eq 'HASH';
	croak "update() expects a hash-ref of options."
		if $options && ref $options ne 'HASH';

	$options ||= {};
	$options->{skip_binary} = 1;

	my $cursor = $self->find($query, $options);

	my $updated = { docs => [], n => 0 }; # will be returned to the caller

	# have we found anything? if not, are we upserting?
	if ($cursor->count) {
		my @docs = $options->{multiple} ? $cursor->all : ($cursor->first); # the documents we're updating

		foreach (@docs) {
			my $name = $_->{_name};

			# update the document object
			$self->_update_document($obj, $_);

			# store the document in the file system
			$self->_store_document($name, $_);

			# add info about this update to the $updated hash
			$updated->{n} += 1;
			push(@{$updated->{docs}}, $name);
		}
	} elsif ($options->{upsert} && ref $query eq 'HASH' && $query->{_name} && !ref $query->{_name}) {
		# we can create one document
		my $doc = {};
		$self->_update_document($obj, $doc);

		# store the document in the fs
		$self->_store_document($query->{_name}, $doc);

		# add info about this upsert to the $updated hash
		$updated->{n} = 1;
		$updated->{docs} = [$query->{_name}];
	}

	return $updated;
}

=head3 remove( [ $name, \%options ] )

=head3 remove( [ \%query, \%options ] )

Performs a query on the collection, and removes every document matched. If a query
is not provided (or if empty string or hash-ref), every document in the collection
is removed. If you pass an options hash-ref with the 'just_one' key holding a true
value, only one document will be removed (the first matched, if any).

=cut

sub remove {
	my ($self, $query, $options) = @_;

	croak "remove() expects a query string (can be empty) or hash-ref (can also be empty)."
		if defined $query && ref $query && ref $query ne 'HASH' && ref $query ne 'Regexp';
	croak "remove() expects a hash-ref of options."
		if $options && ref $options ne 'HASH';

	$query ||= '';

	my $cursor = $self->find($query, $options);

	my $deleted = { docs => [], n => 0 };

	# assuming query was a name search and not an attribute search,
	# i don't want to unnecessarily load all document just so i could
	# delete them, so I'm gonna just iterate through the cursor's
	# _documents array:
	foreach ($options->{just_one} && $cursor->count ? ($cursor->_documents->Keys(0)) : $cursor->count ? $cursor->_documents->Keys : ()) {
		# remove the document
		$self->db->_repo->run('rm', '-r', '-f', $_); # the -r switch is here in case this is a document directory

		# add some info about this deletion
		$deleted->{n} += 1;
		push(@{$deleted->{docs}}, $_);
	}

	return $deleted;
}

=head2 DOCUMENTS ITERATION

=head3 count()

Returns the number of documents in the collection.

=cut

sub count {
	shift->_documents->Length;
}

=head3 sort( [ $order ] )

Sorts the collection's documents. If C<$order> isn't provided, documents
will be sorted alphabetically by name (documents are already sorted by
name by default, so this is only useful for re-sorting).

C<$order> can be any of the following:

=over

=item * An ordered L<Tie::IxHash> object.

=item * An even-numbered array-ref (such as C<< [ 'attr1' => 1, 'attr2' => -1 ] >>).

=back

Of course we are sorting by attributes, so you can still use the '_name'
attribute in C<$order>. When you give an attribute a positive true value,
it will be sorted ascendingly. When you give a negative value, it will
be sorted descendingly. So, for example:

	$coll->sort([ 'birth_date' => -1, '_name' => 1 ])

Will sort the documents in the collection descendingly by the 'birth_date'
attribute, and then ascendingly by the document's name.

Documents that miss any attributes from the C<$order> object always lean
towards the end. If, for example, C<$order> is C<< [ date => 1 ] >>, then
the documents will be sorted ascendingly by the 'date' attribute, and all
documents that don't have the 'date' attribute will propagate to the end.

=cut

sub sort {
	my ($self, $order) = @_;

	croak "sort() expects a Tie::IxHash object or an even-numbered array-ref."
		if $order && (
			!ref $order ||
			(ref $order eq 'ARRAY' && scalar @$order % 2 != 0) ||
			(blessed $order && !$order->isa('Tie::IxHash'))
		);

	# no need to do anything if we have no documents (or only have 1)
	return 1 unless $self->count > 1;

	$order ||= [ '_name' => 1 ];

	$order = Tie::IxHash->new(@$order)
		unless blessed $order && $order->isa('Tie::IxHash');

	# if $order doesn't have sorting by _name, add it explicitly to
	# the end of it as a convention
	$order->Push('_name' => 1)
		unless defined $order->Indices('_name');

	if ($order->Length == 1 && $order->Keys(0) eq '_name') {
		# if we're only sorting by name, there's no need to load
		# the documents, so we can just go ahead and sort
		$self->_documents->OrderByKey;
		$self->_documents->Reorder(reverse $self->_documents->Keys)
			if $order->FETCH('_name') < 0;
	} else {
		# we're gonna have to load the documents (if they're not
		# already loaded).
		$self->_documents->Reorder(sort {
			# load the documents
			my $doc_a = $self->_load_document($self->_documents->Indices($a));
			my $doc_b = $self->_load_document($self->_documents->Indices($b));
			
			# start comparing according to $order
			foreach my $attr ($order->Keys) {
				my $dir = $order->FETCH($attr);
				if (defined $doc_a->{$attr} && !ref $doc_a->{$attr} && defined $doc_b->{$attr} && !ref $doc_b->{$attr}) {
					# are we comparing numerically or alphabetically?
					if ($doc_a->{$attr} =~ m/^\d+(\.\d+)?$/ && $doc_b->{$attr} =~ m/^\d+(\.\d+)?$/) {
						# numerically
						if ($dir > 0) {
							# when $dir is positive, we want $a to be larger than $b
							return 1 if $doc_a->{$attr} > $doc_b->{$attr};
							return -1 if $doc_a->{$attr} < $doc_b->{$attr};
						} elsif ($dir < 0) {
							# when $dir is negative, we want $a to be smaller than $b
							return -1 if $doc_a->{$attr} > $doc_b->{$attr};
							return 1 if $doc_a->{$attr} < $doc_b->{$attr};
						}
					} else {
						# alphabetically
						if ($dir > 0) {
							# when $dir is positive, we want $a to be larger than $b
							return 1 if $doc_a->{$attr} gt $doc_b->{$attr};
							return -1 if $doc_a->{$attr} lt $doc_b->{$attr};
						} elsif ($dir < 0) {
							# when $dir is negative, we want $a to be smaller than $b
							return -1 if $doc_a->{$attr} gt $doc_b->{$attr};
							return 1 if $doc_a->{$attr} lt $doc_b->{$attr};
						}
					}
				} else {
					# documents cannot be compared for this attribute
					# we want documents that have the attribute appear
					# earlier in the collection, so let's find out if
					# one of the documents has the attribute
					return -1 if defined $doc_a->{$attr} && !defined $doc_b->{$attr};
					return 1 if defined $doc_b->{$attr} && !defined $doc_a->{$attr};
					
					# if we're here, either both documents have the
					# attribute but it's non comparable (since it's a
					# reference) or both documents don't have that
					# attribute at all. in both cases, we consider them
					# to be equal when comparing these attributes,
					# so we don't return anything and just continue to
					# the next attribute to sort according to (if any)
				}
			}

			# if we've reached this point, the documents compare entirely
			# so we need to return zero
			return 0;
		} $self->_documents->Keys);
	}

	$self->rewind;

	return $self;
}

=head3 all()

Returns an array of all the documents in the collection (after loading).

=cut

sub all {
	my $self = shift;
	my @results;
	while ($self->has_next) {
		push(@results, $self->next);
	}
	$self->rewind;
	return @results;
}

=head3 has_next()

Returns a true value if the iterator hasn't reached the last of the documents
(and thus C<next()> can be called).

=cut

sub has_next {
	$_[0]->_loc < $_[0]->count;
}

=head3 next()

Returns the document currently pointed to by the iterator, and increases the
iterator to point to the next document.

=cut

sub next {
	my $self = shift;

	return unless $self->has_next;

	my $next = $self->_load_document($self->_loc);
	$self->_inc_loc;
	return $next;
}

=head2 rewind()

Resets to iterator to point to the first document.

=cut

sub rewind {
	$_[0]->_set_loc(0);
}

=head2 first()

Returns the first document in the collection (or C<undef> if none exist),
regardless of the iterator's current position (which will not change).

=cut

sub first {
	my $self = shift;

	return unless $self->count;

	return $self->_load_document(0);
}

=head2 last()

Returns the last document in the collection (or C<undef> if none exist),
regardless of the iterator's current position (which will not change).

=cut

sub last {
	my $self = shift;

	return unless $self->count;

	return $self->_load_document($self->count - 1);
}

=head2 COLLECTION OPERATIONS

=head3 get_parent()

Returns a L<Giddy::Collection> object tied to the parent collection of the collection.
If this method is called on the root collection, C<undef> will be returned.

=cut

sub get_parent {
	my $self = shift;

	return unless $self->path;

	return $self->db->get_collection($self->db->_up($self->path));
}

=head3 get_collection( $name )

Returns a L<Giddy::Collection> object tied to a child-collection named C<$name>.
If the collection does not exist, it will be created. If C<$name> exists in the
collection, but isn't a child collection, this method will croak. C<$name> must
not start with a slash.

=cut

sub get_collection {
	my ($self, $name) = @_;

	croak "You must provide the name of the child-collection to get."
		unless $name;

	return $self->db->get_collection($self->_path_to($name));
}

=head3 list_static_dirs()

Returns a list of all the static-file directories in the collection (if any).

=cut

sub list_static_dirs {
	my $self = shift;

	return map { $self->db->_is_static_dir($self->_path_to($_)) } $self->db->_list_dirs($self->path);
}

=head3 get_static_dir( $name )

Returns a L<Giddy::StaticDirectory> object for a directory of static files named
C<$name>, residing in the collection's directory. If the directory does not exist,
it will be created and marked as a static directory with an empty '.static' file.
If the directory exists but is not a static directory (or a file named C<$name>
exists), this method will croak.

=cut

sub get_static_dir {
	my ($self, $path) = @_;

	croak "You must provide the name of the static directory to load."
		unless $path;

	my $fpath = $self->_path_to($path);

	# try to find such a directory
	if ($self->db->_path_exists($fpath)) {
		croak "Path $fpath already exists but isn't a static-file directory."
			unless $self->db->_is_static_dir($fpath);
	} else {
		# okay, let's create the directory
		$self->db->_create_dir($fpath);
		$self->db->_mark_dir_as_static($fpath);
		$self->db->stage($fpath);
	}

	return Giddy::StaticDirectory->new(path => $fpath, coll => $self);
}

=head3 drop()

Removes the collection from the database. Will not work (and croak) on
the root collection. Every document and sub-collection in the collection will
be removed. This method is not available on L<Giddy::Collection::InMemory> objects.

=cut

sub drop {
	my $self = shift;

	croak "You cannot drop the root collection."
		if $self->path eq '';

	$self->db->_repo->run('rm', '-r', '-f', $self->path);
}

=head1 INTERNAL METHODS

The following methods are only to be used internally.

=head2 _documents()

Returns a sorted Tie::IxHash object of all documents in the collection.

=cut

sub _documents {
	my $self = shift;

	my $docs = Tie::IxHash->new;
	foreach ($self->db->_list_contents($self->path)) {
		my $full_path = $self->_path_to($_);

		# we're only looking for document directories and document files
		if ($self->db->_is_directory($full_path) && $self->db->_is_document_dir($full_path)) {
			$docs->STORE($_ => 'dir');
		} elsif ($self->db->_is_file($full_path)) {
			$docs->STORE($_ => 'file');
		}
	}

	return $docs;
}

=head2 _inc_loc()

=cut

sub _inc_loc {
	my $self = shift;

	$self->_set_loc($self->_loc + 1);
}

=head2 _load_document( $index )

=cut

sub _load_document {
	my ($self, $index) = @_;

	return unless $index >= 0 && $index < $self->count;

	my $name = $self->_documents->Keys($index);
	if (exists $self->_loaded->{$name}) {
		return $self->_loaded->{$name};
	} else {
		my $t = $self->_documents->FETCH($name);
		my $doc;
		if ($t eq 'file') {
			$doc = $self->_query->{coll}->_load_document_file($name);
		} elsif ($t eq 'dir') {
			$doc = $self->_query->{coll}->_load_document_dir($name, $self->_query->{opts}->{skip_binary});
		}
		croak "Failed to load document $name." unless $doc;
		$self->_loaded->{$name} = $doc;
		return $doc;
	}
}

=head2 _path_to( @names )

Returns an internal path created by joining the collection's path and
everything in C<@names> with '/' as a separator. If the collection is the root
collection (and thus has the empty path) than this method will behave correctly
and not return a string that starts with a slash.

=cut

sub _path_to {
	my ($self, @names) = @_;

	unshift(@names, $self->path) if $self->path;
	return join('/', @names);
}

=head2 _build_cached()

=cut

sub _build_cached {
	my $self = shift;

	return $self->db->_path_exists($self->path) ? 1 : 0;
}

=head1 AUTHOR

Ido Perlmuter, C<< <ido at ido50.net> >>

=head1 BUGS

Please report any bugs or feature requests to C<bug-giddy at rt.cpan.org>, or through
the web interface at L<http://rt.cpan.org/NoAuth/ReportBug.html?Queue=Giddy>. I will be notified, and then you'll
automatically be notified of progress on your bug as I make changes.

=head1 SUPPORT

You can find documentation for this module with the perldoc command.

	perldoc Giddy::Collection

You can also look for information at:

=over 4

=item * RT: CPAN's request tracker

L<http://rt.cpan.org/NoAuth/Bugs.html?Dist=Giddy>

=item * AnnoCPAN: Annotated CPAN documentation

L<http://annocpan.org/dist/Giddy>

=item * CPAN Ratings

L<http://cpanratings.perl.org/d/Giddy>

=item * Search CPAN

L<http://search.cpan.org/dist/Giddy/>

=back

=head1 LICENSE AND COPYRIGHT

Copyright 2011 Ido Perlmuter.

This program is free software; you can redistribute it and/or modify it
under the terms of either: the GNU General Public License as published
by the Free Software Foundation; or the Artistic License.

See http://dev.perl.org/licenses/ for more information.

=cut

__PACKAGE__->meta->make_immutable;