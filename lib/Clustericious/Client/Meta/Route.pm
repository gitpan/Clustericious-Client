=head1 NAME

Clustericious::Client::Meta::Route - metadata about a route

=head1 DESCRIPTION

Keep track of metadata about a particular route.  This includes
documentation and attributes.

=head1 SYNOPSIS

    my $meta = Clustericious::Client::Meta::Route->new(
            client_class => 'Yars::Client',
            route_name => 'bucket_map,
        );
    $meta->get('auto_failover');

=head1 SEE ALSO

Clustericious::Client::Meta

=cut

package Clustericious::Client::Meta::Route;
use Clustericious::Client::Meta;
use Mojo::Base qw/-base/;

has 'client_class';
has 'route_name';

=head2 set

Set a route attribute.

  $meta->set(auto_failover => 1);

=cut

sub set {
    my $self = shift;
    return Clustericious::Client::Meta->add_route_attribute(
        $self->client_class, $self->route_name, @_ );
}

=head2 get

Get a route attribute.

 $meta->get('auto_failover');

=cut

sub get {
    my $self = shift;
    return Clustericious::Client::Meta->get_route_attribute(
        $self->client_class, $self->route_name, @_ );
}

=head2 doc

Get documentation for this route.

=cut

sub doc {
    my $self = shift;
    return Clustericious::Client::Meta->get_route_doc(
        $self->client_class, $self->route_name, @_
    );
}

=over

=item set_doc

Set the documentation for a route.

=cut

sub set_doc {
    my $self = shift;
    return Clustericious::Client::Meta->add_route(
        $self->client_class, $self->route_name, @_
    );
}

=item client_class

The class of the client associated with this object.

=item route_name

The name of the route to which this object refers.

=cut

1;

