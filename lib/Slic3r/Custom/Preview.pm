package Slic3r::Custom::Preview;

use strict;
use warnings;

use Slic3r;
use OpenGL qw(:glconstants :glfunctions :glufunctions :glutconstants :glutfunctions);
use base qw(Class::Accessor);
use Math::Trig qw(asin);
use List::Util qw(reduce min max first);
use Slic3r::Geometry qw(X Y Z MIN MAX triangle_normal normalize deg2rad tan);
use File::Basename qw(dirname);

#DIY use image library to capture
use OpenGL::Image;
#use Data::Dumper;
#DIY end - PNI

__PACKAGE__->mk_accessors( qw(
	quat dirty init mview_init object_bounding_box object_shift volumes initpos sphi stheta
	srho simage pheight psize scolors TextureID_FBO FrameBufferID RenderBufferID) );

#DIY use two different gray colors as default
#use constant COLORS => [ [1,1,1], [1,0.5,0.5], [0.5,1,0.5], [0.5,0.5,1] ];
use constant COLORS => [ [0.5,0.5,0.5], [1,1,1] ];
#DIY end - PNI

#DIY define some constant variable to let edit easier
use constant CAP_IMG_LEN => 500;
use constant RHO_DEFAULT => 400;
#DIY end - PNI

# make OpenGL::Array thread-safe
*OpenGL::Array::CLONE_SKIP = sub { 1 };

sub new {
	my ($class, $object, $rho, $theta, $delta, $image_file, $height, $bed_size, $color1, $color2) = @_;
	my $self = $class->SUPER::new();
	
    $self->quat((0, 0, 0, 1));
	#DIY load http daemon passing parameter
#    $self->sphi(45);
#    $self->stheta(-45);
	$self->sphi($theta);
	$self->stheta($delta);
	$self->srho($rho);
	$self->pheight($height);
	$self->psize($bed_size);
	$self->simage($image_file);
	
	# generate color
	my @array_color;
	if (defined($color1)) {
		push(@array_color, $color1);
	}
	else {
		push(@array_color, COLORS->[0]);
	}
	if (defined($color2)) {
		push(@array_color, $color2);
	}
	else {
		push(@array_color, COLORS->[1]);
	}
	$self->scolors(@array_color);
	#DIY end - PNI

    $self->load_object($object);
    
    return $self;
}

sub load_object {
    my ($self, $object) = @_;
    
	my $instance = $object->instances->[0];
	my $xrot = $instance->rotationX;
	my $yrot = $instance->rotationY;
	my $zrot = $instance->rotation;
	my $scale = $instance->scaling_factor;

    my $bb = $object->mesh->bounding_box;
    my $center = $bb->center;
    $self->object_shift(Slic3r::Pointf3->new(-$center->x, -$center->y, -$bb->z_min));  #,,
    $bb->translate(@{ $self->object_shift });
    $self->object_bounding_box($bb);
	#DIY pass 3D center to transform_mesh
	my $rot_center = $object->raw_mesh->bounding_box->center;
	#DIY end - PNI
    
    # group mesh(es) by material
    my @materials = ();
    $self->volumes([]);
    
    # sort volumes: non-modifiers first
    my @volumes = sort { ($a->modifier // 0) <=> ($b->modifier // 0) } @{$object->volumes};
    foreach my $volume (@volumes) {
        my $mesh = $volume->mesh->clone;
		#DIY transform mesh as setting
		$mesh->rotate($zrot, Slic3r::Point->new(0,0));
		$mesh->rotateX($xrot, $rot_center->[Y], $rot_center->[Z]);
		$mesh->rotateY($yrot, $rot_center->[X], $rot_center->[Z]);
		$mesh->scale($scale);
		$mesh->translate(0, 0, $self->object_shift->[Z]);
#		print "shift: " . Dumper(@{ $self->object_shift }); # test
#        $mesh->translate(@{ $self->object_shift });
		#DIY end - PNI
        
        my $material_id = $volume->material_id // '_';
        my $color_idx = first { $materials[$_] eq $material_id } 0..$#materials;
        if (!defined $color_idx) {
            push @materials, $material_id;
            $color_idx = $#materials;
        }
        
        my $color = [ @{$self->scolors->[ $color_idx % scalar(@{$self->scolors}) ]} ];
        push @$color, $volume->modifier ? 0.5 : 1;
        push @{$self->volumes}, my $v = {
            color => $color,
        };
        
        {
            my $vertices = $mesh->vertices;
            my @verts = map @{ $vertices->[$_] }, map @$_, @{$mesh->facets};
            $v->{verts} = OpenGL::Array->new_list(GL_FLOAT, @verts);
        }
        
        {
            my @norms = map { @$_, @$_, @$_ } @{$mesh->normals};
            $v->{norms} = OpenGL::Array->new_list(GL_FLOAT, @norms);
        }
    }
}

# Build a rotation matrix, given a quaternion rotation.
sub quat_to_rotmatrix {
    my ($q) = @_;
  
    my @m = ();
  
    $m[0] = 1.0 - 2.0 * (@$q[1] * @$q[1] + @$q[2] * @$q[2]);
    $m[1] = 2.0 * (@$q[0] * @$q[1] - @$q[2] * @$q[3]);
    $m[2] = 2.0 * (@$q[2] * @$q[0] + @$q[1] * @$q[3]);
    $m[3] = 0.0;

    $m[4] = 2.0 * (@$q[0] * @$q[1] + @$q[2] * @$q[3]);
    $m[5] = 1.0 - 2.0 * (@$q[2] * @$q[2] + @$q[0] * @$q[0]);
    $m[6] = 2.0 * (@$q[1] * @$q[2] - @$q[0] * @$q[3]);
    $m[7] = 0.0;

    $m[8] = 2.0 * (@$q[2] * @$q[0] - @$q[1] * @$q[3]);
    $m[9] = 2.0 * (@$q[1] * @$q[2] + @$q[0] * @$q[3]);
    $m[10] = 1.0 - 2.0 * (@$q[1] * @$q[1] + @$q[0] * @$q[0]);
    $m[11] = 0.0;

    $m[12] = 0.0;
    $m[13] = 0.0;
    $m[14] = 0.0;
    $m[15] = 1.0;
  
    return @m;
}

sub ResetModelView {
    my ($self, $factor) = @_;
    
    glMatrixMode(GL_MODELVIEW);
    glLoadIdentity();

	#DIY adapt view to platform
	# important for real zoom, just take the length of platform as 15cm,
	# and fit the platform with display window
#	my ($img_width, $img_height) = (CAP_IMG_LEN, CAP_IMG_LEN);
#	my $ratio = $factor * min($img_width, $img_height) / max(@{ $self->object_bounding_box->size });
	my $ratio;
	if ($factor > 0 ) {
		$ratio = $factor * CAP_IMG_LEN / $self->pheight;
	} else { #condition: $factor <= 0, special value, just fit to object (not in specification)
		$ratio = 0.9 * CAP_IMG_LEN / max(@{ $self->object_bounding_box->size });
	}
	#DIY end - PNI
	glScalef($ratio, $ratio, 1);
}

sub Resize {
    my ($self) = @_;
    my($x) = CAP_IMG_LEN;
    my($y) = CAP_IMG_LEN;
    my $factor;

    glViewport(0, 0, $x, $y);
 
    glMatrixMode(GL_PROJECTION);
    glLoadIdentity();
	#DIY just let program to display/draw entire of platform and object everytime
#   glOrtho(-$x/2, $x/2, -$y/2, $y/2, 0.5, 2 * max(@{ $self->object_bounding_box->size }));
    glOrtho(-$x/2, $x/2, -$y/2, $y/2,
     -max($self->pheight, @{ $self->object_bounding_box->size }), # near
      max($self->pheight, @{ $self->object_bounding_box->size }) * 2); # far
 
    glMatrixMode(GL_MODELVIEW);
    unless ($self->mview_init) {
        $self->mview_init(1);
        if ($self->srho > 0) {
        	$factor = RHO_DEFAULT / $self->srho;
#        	$factor = $self->srho / RHO_DEFAULT;
        } else { #condition: $self->srho <= 0, special value, just fit to object (not in specification)
        	$factor = 0;
        }
#		$self->ResetModelView(0.9);
        $self->ResetModelView($factor);
    }
	#DIY end - PNI
}
 
sub InitGL {
    my $self = shift;
 
    return if $self->init;
    $self->init(1);
    
    glEnable(GL_NORMALIZE);
    glEnable(GL_LIGHTING);
    glDepthFunc(GL_LESS);
    glEnable(GL_DEPTH_TEST);
    
    # Settings for our light.
    my @LightPos        = (0, 0, 2, 1.0);
    my @LightAmbient    = (0.1, 0.1, 0.1, 1.0);
    my @LightDiffuse    = (0.7, 0.5, 0.5, 1.0);
    my @LightSpecular   = (0.1, 0.1, 0.1, 0.1);
    
    # Enables Smooth Color Shading; try GL_FLAT for (lack of) fun.
    glShadeModel(GL_SMOOTH);
    
    # Set up a light, turn it on.
    glLightfv_p(GL_LIGHT1, GL_POSITION, @LightPos);
    glLightfv_p(GL_LIGHT1, GL_AMBIENT,  @LightAmbient);
    glLightfv_p(GL_LIGHT1, GL_DIFFUSE,  @LightDiffuse);
    glLightfv_p(GL_LIGHT1, GL_SPECULAR, @LightSpecular);
    glEnable(GL_LIGHT1);
      
    # A handy trick -- have surface material mirror the color.
    glColorMaterial(GL_FRONT_AND_BACK, GL_AMBIENT_AND_DIFFUSE);
    glEnable(GL_COLOR_MATERIAL);
}
 
sub Render {
    my ($self) = shift;
    
    $self->InitGL;

    glClear(GL_COLOR_BUFFER_BIT | GL_DEPTH_BUFFER_BIT);
    
#	glClearColor(0.0, 0.0, 0.0, 0.0);
#	glClearDepth(1.0);

    glPushMatrix();

    my $object_size = $self->object_bounding_box->size;
    glTranslatef(0, 0, -max(@$object_size[0..1]));
    my @rotmat = quat_to_rotmatrix($self->quat);
    glMultMatrixd_p(@rotmat[0..15]);
    glRotatef($self->stheta, 1, 0, 0);
    glRotatef($self->sphi, 0, 0, 1);

    my $center = $self->object_bounding_box->center;
    glTranslatef(-$center->x, -$center->y, -$center->z);  #,,

    $self->draw_mesh;

#DIY print string on rendering

#	glColor4f(0.9,0.2,0.2,.75);
#	glRasterPos2i(-100,0);
#	ourPrintString(GLUT_BITMAP_HELVETICA_12, "-100");
#DIY end - PNI
    
    # draw axes
    {
        #DIY make axes in the platform for the real zoom, and draw it in center
#		my $axis_len = 2 * max(@{ $self->object_size });
#		my $axis_len = $self->pheight / 2;
        my $axis_len_x = $self->psize->[X] / 2;
        my $axis_len_y = $self->psize->[Y] / 2;
        my $o_x = $center->x;
        my $o_y = $center->y;
#		print "x: $o_x, y: $o_y\n";
        # TODO need to think about the value Z of O ($center->[Z] or 0)
        #DIY end - PNI
        glLineWidth(2);
        glBegin(GL_LINES);
        # draw line for x axis
        glColor3f(1, 0, 0);
        glVertex3f($o_x, $o_y, 0);
        glVertex3f($axis_len_x + $o_x, $o_y, 0);
        # draw line for y axis
        glColor3f(0, 1, 0);
        glVertex3f($o_x, $o_y, 0);
        glVertex3f($o_x, $axis_len_y + $o_y, 0);
        # draw line for Z axis
        glColor3f(0, 0, 1);
        glVertex3f($o_x, $o_y, 0);
        glVertex3f($o_x, $o_y, $self->pheight); # let axis of Z to be the max value of printer
        glEnd();
        
        # draw ground
        my $ground_z = 0.5;
        glDisable(GL_CULL_FACE);
        glEnable(GL_BLEND);
	     glBlendFunc(GL_SRC_ALPHA, GL_ONE_MINUS_SRC_ALPHA);
        glBegin(GL_QUADS);
        glColor4f(1, 1, 1, 0.5);
        glVertex3f(-$axis_len_x + $o_x, -$axis_len_y + $o_y, -$ground_z);
        glVertex3f($axis_len_x + $o_x, -$axis_len_y + $o_y, -$ground_z);
        glVertex3f($axis_len_x + $o_x, $axis_len_y + $o_y, -$ground_z);
        glVertex3f(-$axis_len_x + $o_x, $axis_len_y + $o_y, -$ground_z);
        glEnd();
        glEnable(GL_CULL_FACE);
        glDisable(GL_BLEND);
        
        # draw grid
        glBegin(GL_LINES);
        glColor4f(1, 1, 1, 0.8);
        for (my $x = -$axis_len_x + $o_x; $x <= $axis_len_x + $o_x; $x += 10) {
            glVertex3f($x, -$axis_len_y + $o_y, 0);
            glVertex3f($x, $axis_len_y + $o_y, 0);
        }
        for (my $y = -$axis_len_y + $o_y; $y <= $axis_len_y + $o_y; $y += 10) {
            glVertex3f(-$axis_len_x + $o_x, $y, 0);
            glVertex3f($axis_len_x + $o_x, $y, 0);
        }
        glEnd();
    }

    glPopMatrix();
    glFlush();
    
	#DIY capture image
	# we have problem of PerlImageMagick in CitrusPerl for Windows, but normally not in Linux,
	# so for windows, we disable check function and convert by ImageMagick in command line
	{
		my $frame_capture = new OpenGL::Image(width=>CAP_IMG_LEN, height=>CAP_IMG_LEN);
		my ($fmt, $size) = $frame_capture->Get('gl_format', 'gl_type');
		glReadPixels_c(0, 0, CAP_IMG_LEN, CAP_IMG_LEN, GL_RGBA, GL_UNSIGNED_BYTE, $frame_capture->Ptr());
		$frame_capture->Save($self->simage);
	}
	#DIY end - PNI

	return;
}

sub draw_mesh {
    my $self = shift;
    
    glEnable(GL_BLEND);
    glBlendFunc(GL_SRC_ALPHA, GL_ONE_MINUS_SRC_ALPHA);
    glEnable(GL_CULL_FACE);
    glEnableClientState(GL_VERTEX_ARRAY);
    glEnableClientState(GL_NORMAL_ARRAY);
    
    foreach my $volume (@{$self->volumes}) {
        glVertexPointer_p(3, $volume->{verts});
        
        glCullFace(GL_BACK);
        glNormalPointer_p($volume->{norms});
        glColor4f(@{ $volume->{color} });
        glDrawArrays(GL_TRIANGLES, 0, $volume->{verts}->elements / 3);
    }
    
    glDisableClientState(GL_NORMAL_ARRAY);
    glDisableClientState(GL_VERTEX_ARRAY);
}

#DIY for preview image rendering
sub InitBuffer { # init offscreen render buffer
	my ($self) = @_;
	
	#FBO want GUI evenif we doesn't display anything
	#TODO FIXME do not use any GUI
	
	# Initialize GLUT/FreeGLUT
	eval {
		glutInit();
	
		# To see OpenGL drawing, take out the GLUT_DOUBLE request.
		glutInitDisplayMode(GLUT_RGBA | GLUT_DOUBLE | GLUT_DEPTH); # for cubie, can not use GLUT_ALPHA mode
#		glutInitWindowSize(CAP_IMG_LEN, CAP_IMG_LEN);
		my $Window_ID = glutCreateWindow( "PROGRAM_TITLE" );
		glutDestroyWindow($Window_ID);
	};

	#FBO
	$self->TextureID_FBO ( glGenTextures_p(1) );
	$self->FrameBufferID ( glGenFramebuffersEXT_p(1) );
	$self->RenderBufferID ( glGenRenderbuffersEXT_p(1) );

	glBindFramebufferEXT(GL_FRAMEBUFFER_EXT, $self->FrameBufferID);
	glBindTexture(GL_TEXTURE_2D, $self->TextureID_FBO);

	glTexImage2D_c(GL_TEXTURE_2D, 0, GL_RGBA8, CAP_IMG_LEN, CAP_IMG_LEN, 0, GL_RGBA, GL_UNSIGNED_BYTE, 0);
	glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_LINEAR);
	glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_LINEAR);

	glFramebufferTexture2DEXT(GL_FRAMEBUFFER_EXT, GL_COLOR_ATTACHMENT0_EXT, GL_TEXTURE_2D, $self->TextureID_FBO, 0);
	glBindRenderbufferEXT(GL_RENDERBUFFER_EXT, $self->RenderBufferID);
	glRenderbufferStorageEXT(GL_RENDERBUFFER_EXT, GL_DEPTH_COMPONENT24, CAP_IMG_LEN, CAP_IMG_LEN);
	glFramebufferRenderbufferEXT(GL_FRAMEBUFFER_EXT, GL_DEPTH_ATTACHMENT_EXT, GL_RENDERBUFFER_EXT, $self->RenderBufferID);
	
	return;
}

sub ReleaseRessource { # release ressource of render buffer
	my ($self) = @_;
	
	glBindRenderbufferEXT( GL_RENDERBUFFER_EXT, 0 );
	glBindFramebufferEXT( GL_FRAMEBUFFER_EXT, 0 );
	
	glDeleteRenderbuffersEXT_p( $self->RenderBufferID ) if ($self->RenderBufferID);
	glDeleteFramebuffersEXT_p( $self->FrameBufferID ) if ($self->FrameBufferID);
	
	glDeleteTextures_p($self->TextureID_FBO);
	
	return;
}

sub ourPrintString {
	my ($font, $str) = @_;
	my @c = split '', $str;

	for(@c) {
		glutBitmapCharacter($font, ord $_);
	}
	
	return;
}
#DIY end - PNI

1;
