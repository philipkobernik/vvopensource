
#import "VVSpriteGLView.h"
#import <OpenGL/CGLMacro.h>
#import "VVBasicMacros.h"
//#import "VVControl.h"
#import "VVView.h"




#define VVBITMASKCHECK(mask,flagToCheck) ((mask & flagToCheck) == flagToCheck) ? ((BOOL)YES) : ((BOOL)NO)

long			_spriteGLViewSysVers;



@implementation VVSpriteGLView


+ (void) initialize	{
	OSErr			err;
	SInt32			vers;
	
	err = Gestalt(gestaltSystemVersionMinor,&vers);
	if (err == noErr)
		_spriteGLViewSysVers = vers;
	else
		_spriteGLViewSysVers = 6;
	
	//NSLog(@"\t\t_spriteGLViewSysVers = %ld",_spriteGLViewSysVers);
}
- (id) initWithFrame:(NSRect)f pixelFormat:(NSOpenGLPixelFormat *)p	{
	//NSLog(@"%s",__func__);
	if (self = [super initWithFrame:f pixelFormat:p])	{
		[self generalInit];
		return self;
	}
	[self release];
	return nil;
}
- (id) initWithCoder:(NSCoder *)c	{
	//NSLog(@"%s",__func__);
	if (self = [super initWithCoder:c])	{
		[self generalInit];
		return self;
	}
	[self release];
	return nil;
}
- (void) generalInit	{
	//NSLog(@"%s ... %@, %p",__func__,[self class],self);
	if (_spriteGLViewSysVers >= 7)	{
		[(id)self setWantsBestResolutionOpenGLSurface:YES];
		NSRect		bounds = [self bounds];
		NSRect		realBounds = [(id)self convertRectToBacking:bounds];
		boundsToRealBoundsMultiplier = (realBounds.size.width/bounds.size.width);
	}
	else
		boundsToRealBoundsMultiplier = 1.0;
	//NSLog(@"\t\t%s, BTRBM is %f for %@",__func__,boundsToRealBoundsMultiplier,self);
	[[NSNotificationCenter defaultCenter]
		addObserver:self
		selector:@selector(_glContextNeedsRefresh:)
		name:NSViewGlobalFrameDidChangeNotification
		object:self];
	
	deleted = NO;
	initialized = NO;
	flipped = NO;
	vvSubviews = [[MutLockArray alloc] init];
	//needsReshape = YES;
	spriteManager = [[VVSpriteManager alloc] init];
	spritesNeedUpdate = YES;
	lastMouseEvent = nil;
	drawBorder = NO;
	for (long i=0;i<4;++i)	{
		clearColor[i] = (GLfloat)0.0;
		borderColor[i] = (GLfloat)0.0;
	}
	mouseDownModifierFlags = 0;
	mouseDownEventType = VVSpriteEventNULL;
	modifierFlags = 0;
	mouseIsDown = NO;
	clickedSubview = nil;
	
	pthread_mutexattr_t		attr;
	
	pthread_mutexattr_init(&attr);
	//pthread_mutexattr_settype(&attr,PTHREAD_MUTEX_NORMAL);
	pthread_mutexattr_settype(&attr,PTHREAD_MUTEX_RECURSIVE);
	pthread_mutex_init(&glLock,&attr);
	pthread_mutexattr_destroy(&attr);
	
	flushMode = VVFlushModeGL;
	
	fenceMode = VVFenceModeEveryRefresh;
	fenceA = 0;
	fenceB = 0;
	waitingForFenceA = YES;
	fenceADeployed = NO;
	fenceBDeployed = NO;
	fenceLock = OS_SPINLOCK_INIT;
	//NSLog(@"\t\t%s ... %@, %p - FINISHED",__func__,[self class],self);
}
- (void) awakeFromNib	{
	//NSLog(@"%s",__func__);
	spritesNeedUpdate = YES;
}
- (void) prepareToBeDeleted	{
	NSMutableArray		*subCopy = [vvSubviews lockCreateArrayCopy];
	if (subCopy != nil)	{
		[subCopy retain];
		for (id subview in subCopy)
			[self removeVVSubview:subview];
		[subCopy removeAllObjects];
		[subCopy release];
		subCopy = nil;
	}
	
	if (spriteManager != nil)
		[spriteManager prepareToBeDeleted];
	spritesNeedUpdate = NO;
	deleted = YES;
	
	pthread_mutex_lock(&glLock);
	OSSpinLockLock(&fenceLock);
		//NSLog(@"\t\tdeleting fences %ld & %ld in context %p",fenceA,fenceB,[self openGLContext]);
		CGLContextObj		cgl_ctx = [[self openGLContext] CGLContextObj];
		glDeleteFencesAPPLE(1,&fenceA);
		fenceA = 0;
		fenceADeployed = NO;
		glDeleteFencesAPPLE(1,&fenceB);
		fenceB = 0;
		fenceBDeployed = NO;
	OSSpinLockUnlock(&fenceLock);
	pthread_mutex_unlock(&glLock);
	
	[[NSNotificationCenter defaultCenter]
		removeObserver:self
		name:NSViewGlobalFrameDidChangeNotification
		object:self];
}
- (void) dealloc	{
	//NSLog(@"%s",__func__);
	if (!deleted)
		[self prepareToBeDeleted];
	VVRELEASE(spriteManager);
	VVRELEASE(lastMouseEvent);
	VVRELEASE(vvSubviews);
	pthread_mutex_destroy(&glLock);
	[super dealloc];
}


/*===================================================================================*/
#pragma mark --------------------- overrides
/*------------------------------------*/


- (void) setOpenGLContext:(NSOpenGLContext *)c	{
	//NSLog(@"%s",__func__);
	pthread_mutex_lock(&glLock);
		OSSpinLockLock(&fenceLock);
		CGLContextObj		cgl_ctx = [[self openGLContext] CGLContextObj];
		if (fenceA > 0)
			glDeleteFencesAPPLE(1,&fenceA);
		fenceA = 0;
		fenceADeployed = NO;
		if (fenceB > 0)
			glDeleteFencesAPPLE(1,&fenceB);
		fenceB = 0;
		fenceBDeployed = NO;
		OSSpinLockUnlock(&fenceLock);
		
		[super setOpenGLContext:c];
		[c setView:self];
		initialized = NO;
	pthread_mutex_unlock(&glLock);
	//needsReshape = YES;
}

- (BOOL) acceptsFirstMouse:(NSEvent *)theEvent	{
	return YES;
}
- (BOOL) isOpaque	{
	return YES;
}
- (BOOL) acceptsFirstResponder	{
	return YES;
}
- (BOOL) becomeFirstResponder	{
	return YES;
}
- (BOOL) resignFirstResponder	{
	return YES;
}
- (BOOL) needsPanelToBecomeKey	{
	return YES;
}
- (void) removeFromSuperview	{
	pthread_mutex_lock(&glLock);
	[super removeFromSuperview];
	pthread_mutex_unlock(&glLock);
}
/*
- (NSView *) hitTest:(NSPoint)p	{
	NSLog(@"%s ... (%f, %f)",__func__,p.x,p.y);
	if (deleted || vvSubviews==nil)
		return nil;
	id			tmpSubview = nil;
	if ([vvSubviews count]>0)	{
		[vvSubviews rdlock];
		for (VVView *viewPtr in [vvSubviews array])	{
			tmpSubview = [viewPtr vvSubviewHitTest:p];
			if (tmpSubview != nil)
				break;
		}
		[vvSubviews unlock];
	}
	NSLog(@"\t\ti appear to have clicked on %@",tmpSubview);
	return tmpSubview;
}
*/
- (void) keyDown:(NSEvent *)event	{
	NSLog(@"%s",__func__);
	//[VVControl keyPressed:event];
	//[super keyDown:event];
}
- (void) keyUp:(NSEvent *)event	{
	NSLog(@"%s",__func__);
	//[VVControl keyPressed:event];
	//[super keyUp:event];
}


/*===================================================================================*/
#pragma mark --------------------- subview-related
/*------------------------------------*/


- (void) addVVSubview:(id)n	{
	//NSLog(@"%s",__func__);
	if (deleted || n==nil)
		return;
	if (![n isKindOfClass:[VVView class]])
		return;
	
	[vvSubviews wrlock];
	if (![vvSubviews containsIdenticalPtr:n])	{
		[vvSubviews insertObject:n atIndex:0];
		[n setContainerView:self];
	}
	[vvSubviews unlock];
	[self setNeedsDisplay:YES];
}
- (void) removeVVSubview:(id)n	{
	//NSLog(@"%s",__func__);
	if (deleted || n==nil)
		return;
	if (![n isKindOfClass:[VVView class]])
		return;
	[n retain];
	[vvSubviews lockRemoveIdenticalPtr:n];
	[n setContainerView:nil];
	[n release];
}
- (id) vvSubviewHitTest:(NSPoint)p	{
	//NSLog(@"%s ... (%f, %f)",__func__,p.x,p.y);
	if (deleted || vvSubviews==nil)
		return nil;
	id			tmpSubview = nil;
	if ([vvSubviews count]>0)	{
		[vvSubviews rdlock];
		for (VVView *viewPtr in [vvSubviews array])	{
			NSRect		tmpFrame = [viewPtr frame];
			NSPoint		localPoint = NSMakePoint(p.x-tmpFrame.origin.x, p.y-tmpFrame.origin.y);
			tmpSubview = [viewPtr vvSubviewHitTest:localPoint];
			if (tmpSubview != nil)
				break;
		}
		[vvSubviews unlock];
	}
	//NSLog(@"\t\ti appear to have clicked on %@",tmpSubview);
	return tmpSubview;
}


/*===================================================================================*/
#pragma mark --------------------- frame-related
/*------------------------------------*/


- (void) setFrame:(NSRect)f	{
	//NSLog(@"%s ... %@, (%0.2f, %0.2f) %0.2f x %0.2f",__func__, self, f.origin.x, f.origin.y, f.size.width, f.size.height);
	pthread_mutex_lock(&glLock);
		[super setFrame:f];
		[self updateSprites];
		//spritesNeedUpdate = YES;
		//needsReshape = YES;
		initialized = NO;
	pthread_mutex_unlock(&glLock);
	
	//	update the bounds to real bounds multiplier
	if (_spriteGLViewSysVers>=7 && [(id)self wantsBestResolutionOpenGLSurface])	{
		NSRect		bounds = [self bounds];
		NSRect		realBounds = [(id)self convertRectToBacking:bounds];
		boundsToRealBoundsMultiplier = (realBounds.size.width/bounds.size.width);
	}
	else
		boundsToRealBoundsMultiplier = 1.0;
	//NSLog(@"\t\t%s, BTRBM is %f for %@",__func__,boundsToRealBoundsMultiplier,self);
	
	//NSLog(@"\t\t%s - FINISHED",__func__);
}
- (void) setFrameSize:(NSSize)n	{
	//NSLog(@"%s ... %@, %f x %f",__func__,self,n.width,n.height);
	NSSize			oldSize = [self frame].size;
	[super setFrameSize:n];
	
	if ([self autoresizesSubviews])	{
		double		widthDelta = n.width - oldSize.width;
		double		heightDelta = n.height - oldSize.height;
		[vvSubviews rdlock];
		for (VVView *viewPtr in [vvSubviews array])	{
			VVViewResizeMask	viewResizeMask = [viewPtr autoresizingMask];
			NSRect				viewNewFrame = [viewPtr frame];
			//NSRectLog(@"\t\torig viewNewFrame is",viewNewFrame);
			int					hSubDivs = 0;
			int					vSubDivs = 0;
			if (VVBITMASKCHECK(viewResizeMask,VVViewResizeMinXMargin))
				++hSubDivs;
			if (VVBITMASKCHECK(viewResizeMask,VVViewResizeMaxXMargin))
				++hSubDivs;
			if (VVBITMASKCHECK(viewResizeMask,VVViewResizeWidth))
				++hSubDivs;
			
			if (VVBITMASKCHECK(viewResizeMask,VVViewResizeMinYMargin))
				++vSubDivs;
			if (VVBITMASKCHECK(viewResizeMask,VVViewResizeMaxYMargin))
				++vSubDivs;
			if (VVBITMASKCHECK(viewResizeMask,VVViewResizeHeight))
				++vSubDivs;
			
			if (hSubDivs>0 || vSubDivs>0)	{
				if (hSubDivs>0 && VVBITMASKCHECK(viewResizeMask,VVViewResizeWidth))
					viewNewFrame.size.width += widthDelta/hSubDivs;
				if (vSubDivs>0 && VVBITMASKCHECK(viewResizeMask,VVViewResizeHeight))
					viewNewFrame.size.height += heightDelta/vSubDivs;
				if (VVBITMASKCHECK(viewResizeMask,VVViewResizeMinXMargin))
					viewNewFrame.origin.x += widthDelta/hSubDivs;
				if (VVBITMASKCHECK(viewResizeMask,VVViewResizeMinYMargin))
					viewNewFrame.origin.y += heightDelta/vSubDivs;
			}
			//NSRectLog(@"\t\tmod viewNewFrame is",viewNewFrame);
			[viewPtr setFrame:viewNewFrame];
		}
		[vvSubviews unlock];
	}
	
	if (!NSEqualSizes(oldSize,n))	{
		//NSLog(@"\t\tsized changed!");
		//	update the bounds to real bounds multiplier
		if (_spriteGLViewSysVers>=7 && [(id)self wantsBestResolutionOpenGLSurface])	{
			NSRect		bounds = [self bounds];
			NSRect		realBounds = [(id)self convertRectToBacking:bounds];
			boundsToRealBoundsMultiplier = (realBounds.size.width/bounds.size.width);
		}
		else
			boundsToRealBoundsMultiplier = 1.0;
		//NSLog(@"\t\t%s, BTRBM is %f for %@",__func__,boundsToRealBoundsMultiplier,self);
		
		pthread_mutex_lock(&glLock);
		initialized = NO;
		pthread_mutex_unlock(&glLock);
	}
}
- (void) updateSprites	{
	spritesNeedUpdate = NO;
}
- (void) _glContextNeedsRefresh:(NSNotification *)note	{
	[self setSpritesNeedUpdate:YES];
	//	update the bounds to real bounds multiplier
	if (_spriteGLViewSysVers>=7 && [(id)self wantsBestResolutionOpenGLSurface])	{
		NSRect		bounds = [self bounds];
		NSRect		realBounds = [(id)self convertRectToBacking:bounds];
		boundsToRealBoundsMultiplier = (realBounds.size.width/bounds.size.width);
	}
	else
		boundsToRealBoundsMultiplier = 1.0;
}
- (void) reshape	{
	//NSLog(@"%s",__func__);
	spritesNeedUpdate = YES;
	initialized = NO;
}
- (void) update	{
	spritesNeedUpdate = YES;
	initialized = NO;
}


- (void) _lock	{
	pthread_mutex_lock(&glLock);
}
- (void) _unlock	{
	pthread_mutex_unlock(&glLock);
}
- (NSRect) realBounds	{
	if (_spriteGLViewSysVers >= 7)
		return [(id)self convertRectToBacking:[self bounds]];
	else
		return [self bounds];
}
- (double) boundsToRealBoundsMultiplier	{
	return boundsToRealBoundsMultiplier;
}


/*===================================================================================*/
#pragma mark --------------------- UI
/*------------------------------------*/


- (void) mouseDown:(NSEvent *)e	{
	//NSLog(@"%s",__func__);
	if (deleted)
		return;
	VVRELEASE(lastMouseEvent);
	if (e != nil)
		lastMouseEvent = [e retain];
	mouseIsDown = YES;
	NSPoint		locationInWindow = [e locationInWindow];
	NSPoint		localPoint = [self convertPoint:locationInWindow fromView:nil];
	localPoint = NSMakePoint(localPoint.x*boundsToRealBoundsMultiplier, localPoint.y*boundsToRealBoundsMultiplier);
	//NSPointLog(@"\t\tlocalPoint is",localPoint);
	//	if i have subviews and i clicked on one of them, skip the sprite manager
	if ([[self vvSubviews] count]>0)	{
		clickedSubview = [self vvSubviewHitTest:localPoint];
		if (clickedSubview == self) clickedSubview = nil;
		//NSLog(@"\t\tclickedSubview is %@",clickedSubview);
		//NSRectLog(@"\t\tclickedSubview frame is",[clickedSubview frame]);
		if (clickedSubview != nil)	{
			[clickedSubview mouseDown:e];
			return;
		}
	}
	//	else there aren't any subviews or i didn't click on any of them- do the sprite manager
	mouseDownModifierFlags = [e modifierFlags];
	modifierFlags = mouseDownModifierFlags;
	if ((mouseDownModifierFlags&NSControlKeyMask)==NSControlKeyMask)	{
		mouseDownEventType = VVSpriteEventRightDown;
		[spriteManager localRightMouseDown:localPoint modifierFlag:mouseDownModifierFlags];
	}
	else	{
		mouseDownEventType = VVSpriteEventDown;
		[spriteManager localMouseDown:localPoint modifierFlag:mouseDownModifierFlags];
	}
}
- (void) rightMouseDown:(NSEvent *)e	{
	//NSLog(@"%s",__func__);
	if (deleted)
		return;
	VVRELEASE(lastMouseEvent);
	if (e != nil)
		lastMouseEvent = [e retain];
	mouseIsDown = YES;
	NSPoint		locationInWindow = [e locationInWindow];
	NSPoint		localPoint = [self convertPoint:locationInWindow fromView:nil];
	localPoint = NSMakePoint(localPoint.x*boundsToRealBoundsMultiplier, localPoint.y*boundsToRealBoundsMultiplier);
	//NSPointLog(@"\t\tlocalPoint is",localPoint);
	//	if i have subviews and i clicked on one of them, skip the sprite manager
	if ([[self vvSubviews] count]>0)	{
		clickedSubview = [self vvSubviewHitTest:localPoint];
		//NSLog(@"\t\tclickedSubview is %@",clickedSubview);
		if (clickedSubview == self) clickedSubview = nil;
		if (clickedSubview != nil)	{
			[clickedSubview rightMouseDown:e];
			return;
		}
	}
	mouseDownModifierFlags = [e modifierFlags];
	mouseDownEventType = VVSpriteEventRightDown;
	modifierFlags = mouseDownModifierFlags;
	//	else there aren't any subviews or i didn't click on any of them- do the sprite manager
	[spriteManager localRightMouseDown:localPoint modifierFlag:mouseDownModifierFlags];
}
- (void) rightMouseUp:(NSEvent *)e	{
	if (deleted)
		return;
	VVRELEASE(lastMouseEvent);
	if (e != nil)
		lastMouseEvent = [e retain];
	mouseIsDown = NO;
	NSPoint		localPoint = [self convertPoint:[e locationInWindow] fromView:nil];
	localPoint = NSMakePoint(localPoint.x*boundsToRealBoundsMultiplier, localPoint.y*boundsToRealBoundsMultiplier);
	//	if i clicked on a subview earlier, pass mouse events to it instead of the sprite manager
	if (clickedSubview != nil)
		[clickedSubview rightMouseUp:e];
	else
		[spriteManager localRightMouseUp:localPoint];
}
- (void) mouseDragged:(NSEvent *)e	{
	if (deleted)
		return;
	VVRELEASE(lastMouseEvent);
	if (e != nil)//	if i clicked on a subview earlier, pass mouse events to it instead of the sprite manager
		lastMouseEvent = [e retain];
	
	modifierFlags = [e modifierFlags];
	NSPoint		localPoint = [self convertPoint:[e locationInWindow] fromView:nil];
	localPoint = NSMakePoint(localPoint.x*boundsToRealBoundsMultiplier, localPoint.y*boundsToRealBoundsMultiplier);
	//	if i clicked on a subview earlier, pass mouse events to it instead of the sprite manager
	if (clickedSubview != nil)
		[clickedSubview mouseDragged:e];
	else
		[spriteManager localMouseDragged:localPoint];
}
- (void) rightMouseDragged:(NSEvent *)e	{
	[self mouseDragged:e];
}
- (void) mouseUp:(NSEvent *)e	{
	if (deleted)
		return;
	
	if (mouseDownEventType == VVSpriteEventRightDown)	{
		[self rightMouseUp:e];
		return;
	}
	
	VVRELEASE(lastMouseEvent);
	if (e != nil)
		lastMouseEvent = [e retain];
	
	modifierFlags = [e modifierFlags];
	mouseIsDown = NO;
	NSPoint		localPoint = [self convertPoint:[e locationInWindow] fromView:nil];
	localPoint = NSMakePoint(localPoint.x*boundsToRealBoundsMultiplier, localPoint.y*boundsToRealBoundsMultiplier);
	//	if i clicked on a subview earlier, pass mouse events to it instead of the sprite manager
	if (clickedSubview != nil)
		[clickedSubview mouseUp:e];
	else
		[spriteManager localMouseUp:localPoint];
}


/*===================================================================================*/
#pragma mark --------------------- drawing
/*------------------------------------*/


- (void) lockFocus	{
	if (deleted)	{
		[super lockFocus];
		return;
	}
	
	pthread_mutex_lock(&glLock);
	[super lockFocus];
	pthread_mutex_unlock(&glLock);
}
- (void) drawRect:(NSRect)r	{
	//NSLog(@"%s",__func__);
	if (deleted)
		return;
	
	id			myWin = [self window];
	if (myWin == nil)
		return;
	
	//pthread_mutex_lock(&glLock);
	if (pthread_mutex_trylock(&glLock) != 0)	{	//	returns 0 if successful- so if i can't get a gl lock, skip drawing!
		//NSLog(@"\t\tcouldn't get GL lock, bailing %s",__func__);
		return;
	}
	
		//	if the sprites need to be updated, do so now...this should probably be done inside the gl lock!
		if (spritesNeedUpdate)
			[self updateSprites];
		
		if (!initialized)	{
			[self initializeGL];
			initialized = YES;
		}
		NSOpenGLContext		*context = [self openGLContext];
		CGLContextObj		cgl_ctx = [context CGLContextObj];
		
		//	lock around the fence, determine whether i should proceed with the render or not
		OSSpinLockLock(&fenceLock);
		BOOL		proceedWithRender = NO;
		//	if the fences are broken, i'm going to proceed with rendering and ignore fencing
		if ((fenceA < 1) || (fenceB < 1))
			proceedWithRender = YES;
		//	else the fences are fine- fence based on the fencing mode
		else	{
			//	if the fence mode wants to draw every refresh, proceed with rendering
			if ((fenceMode==VVFenceModeEveryRefresh) || (fenceMode==VVFenceModeFinish))	{
				//NSLog(@"\t\tfence mode is every refresh!");
				proceedWithRender = YES;
			}
			//	else the fence mode *isn't* drawing every refresh- i need to test fenceA no matter what
			else	{
				//	if i'm in single-buffer mode but i'm not waiting for fenceA, something's wrong- i should be waiting for A!
				if ((fenceMode==VVFenceModeSBSkip) && (!waitingForFenceA))
					waitingForFenceA = YES;
				
				//	if i'm waiting for fence A....
				if (waitingForFenceA)	{
					//	if fence A hasn't been deployed, proceed with rendering anyway
					if (!fenceADeployed)
						proceedWithRender = YES;
					else	{
						proceedWithRender = glTestFenceAPPLE(fenceA);
						fenceADeployed = (proceedWithRender)?NO:YES;
					}
					//if (proceedWithRender)	{
					//	//NSLog(@"\t\tfenceA executed- clear to render");
					//}
					//else	{
					//	//NSLog(@"\t\tfenceA hasn't executed yet");
					//}
					
				}
				//	if i'm in DB skip mode and i'm not waiting for fence A...
				if ((fenceMode==VVFenceModeDBSkip) && (!waitingForFenceA))	{
					//	if fence B hasn't been deployed, proceed with rendering anyway
					if (!fenceBDeployed)
						proceedWithRender = YES;
					else	{
						proceedWithRender = glTestFenceAPPLE(fenceB);
						fenceBDeployed = (proceedWithRender)?NO:YES;
					}
					//if (proceedWithRender)	{
					//	//NSLog(@"\t\tfenceB executed- clear to render");
					//}
					//else	{
					//	//NSLog(@"\t\tfenceB hasn't executed yet");
					//}
				}
			}
		}
		OSSpinLockUnlock(&fenceLock);
		
		
		if (proceedWithRender)	{
			
			//	clear the view
			glClear(GL_COLOR_BUFFER_BIT);
			
			//	tell the sprite manager to start drawing the sprites
			if (spriteManager != nil)	{
				if (_spriteGLViewSysVers >= 8)
					[spriteManager drawRect:[(id)self convertRectToBacking:r]];
				else
					[spriteManager drawRect:r];
			}
			
			
			
			//	tell the subviews to draw
			[vvSubviews rdlock];
				if ([vvSubviews count]>0)	{
					//	before i begin, enable the scissor test and get my bounds
					NSRect		bounds = [self realBounds];
					glEnable(GL_SCISSOR_TEST);
					//	run through all the subviews (last to first), drawing them
					NSEnumerator		*it = [[vvSubviews array] reverseObjectEnumerator];
					VVView				*viewPtr;
					while (viewPtr = [it nextObject])	{
						NSRect				tmpFrame = [viewPtr frame];
						GLfloat				tmpRotation = [viewPtr boundsRotation];
						NSPoint				tmpOrigin = [viewPtr boundsOrigin];
						if (NSIntersectsRect(r,tmpFrame))	{
							//	use scissor to clip drawing
							glScissor(tmpFrame.origin.x, tmpFrame.origin.y, tmpFrame.size.width, tmpFrame.size.height);
							//	apply transformation matrices so that when the view draws, its origin in GL is the correct location in the context
							glPushMatrix();
							glTranslatef(tmpFrame.origin.x, tmpFrame.origin.y, 0.0);
							if (tmpRotation != 0.0)
								glRotatef(tmpRotation, 0.0, 0.0, 1.0);
							if (tmpOrigin.x!=0.0 || tmpOrigin.y!=0.0)
								glTranslatef(tmpOrigin.x, -1.0*tmpOrigin.y, 0.0);
							
							//	now tell the view to do its drawing!
							tmpFrame.origin = NSMakePoint(0,0);
							[viewPtr _drawRect:tmpFrame inContext:cgl_ctx];
							
							glPopMatrix();
						}
					}
					//	now that i'm done drawing subviews, set scissor back to my full bounds and disable the test
					glScissor(bounds.origin.x, bounds.origin.y, bounds.size.width, bounds.size.height);
					glDisable(GL_SCISSOR_TEST);
				}
			[vvSubviews unlock];
			
			
			
			//	if appropriate, draw the border
			if (drawBorder)	{
				glColor4f(borderColor[0],borderColor[1],borderColor[2],borderColor[3]);
				glEnableClientState(GL_VERTEX_ARRAY);
				glDisableClientState(GL_TEXTURE_COORD_ARRAY);
				GLSTROKERECT([self realBounds]);
			}
			
			//	flush!
			switch (flushMode)	{
				case VVFlushModeGL:
					glFlush();
					break;
				case VVFlushModeCGL:
					CGLFlushDrawable(cgl_ctx);
					break;
				case VVFlushModeNS:
					[context flushBuffer];
					break;
				case VVFlushModeApple:
					glFlushRenderAPPLE();
					break;
				case VVFlushModeFinish:
					glFinish();
					break;
			}
			
			//	lock around the fence, insert a fence in the command stream, and swap fences
			OSSpinLockLock(&fenceLock);
			if ((fenceMode!=VVFenceModeEveryRefresh) && (fenceMode!=VVFenceModeFinish) && (fenceA > 0) && (fenceB > 0))	{
				if (waitingForFenceA)	{
					glSetFenceAPPLE(fenceA);
					fenceADeployed = YES;
					//NSLog(@"\t\tdone drawing, inserting fenceA into stream");
					if (fenceMode == VVFenceModeDBSkip)
						waitingForFenceA = NO;
				}
				else	{
					glSetFenceAPPLE(fenceB);
					fenceBDeployed = YES;
					//NSLog(@"\t\tdone drawing, inserting fenceB into stream");
					waitingForFenceA = YES;
				}
			}
			OSSpinLockUnlock(&fenceLock);
			
			//	call 'finishedDrawing' so subclasses of me have a chance to perform post-draw cleanup
			[self finishedDrawing];
		}
		//else
		//	NSLog(@"\t\terr: sprite GL view fence prevented output!");
	
	pthread_mutex_unlock(&glLock);
}
- (void) initializeGL	{
	//NSLog(@"%s ... %p",__func__,self);
	if (deleted)
		return;
	CGLContextObj		cgl_ctx = [[self openGLContext] CGLContextObj];
	//NSRect				bounds = [self bounds];
	//long				cpSwapInterval = 1;
	//[[self openGLContext] setValues:(GLint *)&cpSwapInterval forParameter:NSOpenGLCPSwapInterval];
	
	OSSpinLockLock(&fenceLock);
	if (fenceA < 1)	{
		glGenFencesAPPLE(1,&fenceA);
		fenceADeployed = NO;
	}
	if (fenceB < 1)	{
		glGenFencesAPPLE(1,&fenceB);
		fenceBDeployed = NO;
	}
	OSSpinLockUnlock(&fenceLock);
	
	glEnableClientState(GL_VERTEX_ARRAY);
	
	glEnable(GL_BLEND);
	glBlendFunc(GL_SRC_ALPHA, GL_ONE_MINUS_SRC_ALPHA);
	//glPixelStorei(GL_UNPACK_ALIGNMENT, 1);
	//glTexEnvi(GL_TEXTURE_ENV, GL_TEXTURE_ENV_MODE, GL_MODULATE);
	glHint(GL_CLIP_VOLUME_CLIPPING_HINT_EXT, GL_FASTEST);
	
	
	//	from http://developer.apple.com/library/mac/#documentation/GraphicsImaging/Conceptual/OpenGL-MacProgGuide/opengl_designstrategies/opengl_designstrategies.html%23//apple_ref/doc/uid/TP40001987-CH2-SW17
	//glDisable(GL_DITHER);
	//glDisable(GL_ALPHA_TEST);
	//glDisable(GL_STENCIL_TEST);
	//glDisable(GL_FOG);
	//glDisable(GL_TEXTURE_2D);
	glPixelZoom((GLuint)1.0,(GLuint)1.0);
	
	NSRect		bounds = [self realBounds];
	glViewport(0, 0, (GLsizei) bounds.size.width, (GLsizei) bounds.size.height);
	
	//	moved in from drawRect:
	glMatrixMode(GL_MODELVIEW);
	glLoadIdentity();
	glMatrixMode(GL_PROJECTION);
	glLoadIdentity();
	if (flipped)
		glOrtho(bounds.origin.x, bounds.origin.x+bounds.size.width, bounds.origin.y, bounds.origin.y+bounds.size.height, 1.0, -1.0);
	else
		glOrtho(bounds.origin.x, bounds.origin.x+bounds.size.width, bounds.origin.y+bounds.size.height, bounds.origin.y, 1.0, -1.0);
	
	//	always here!
	//glDisable(GL_DEPTH_TEST);
	glClearColor(clearColor[0],clearColor[1],clearColor[2],clearColor[3]);
	
	initialized = YES;
}
/*	this method exists so subclasses of me have an opportunity to do something after drawing 
	has completed.  this is particularly handy with the GL view, as drawing does not complete- and 
	therefore resources have to stay available- until after glFlush() has been called.		*/
- (void) finishedDrawing	{

}


@synthesize deleted;
@synthesize initialized;
- (void) setFlipped:(BOOL)n	{
	BOOL		changing = (n==flipped) ? NO : YES;
	flipped = n;
	if (changing)
		initialized = NO;
}
- (BOOL) flipped	{
	return flipped;
}
@synthesize boundsToRealBoundsMultiplier;
@synthesize vvSubviews;
- (void) setSpritesNeedUpdate:(BOOL)n	{
	spritesNeedUpdate = n;
}
- (BOOL) spritesNeedUpdate	{
	return spritesNeedUpdate;
}
- (void) setSpritesNeedUpdate	{
	spritesNeedUpdate = YES;
}
- (NSEvent *) lastMouseEvent	{
	return lastMouseEvent;
}
- (VVSpriteManager *) spriteManager	{
	return spriteManager;
}
- (void) setClearColor:(NSColor *)c	{
	if ((deleted)||(c==nil))
		return;
	NSColorSpace	*devRGBColorSpace = [NSColorSpace deviceRGBColorSpace];
	NSColor			*calibratedColor = ((void *)[c colorSpace]==(void *)devRGBColorSpace) ? c :[c colorUsingColorSpaceName:NSDeviceRGBColorSpace];
	pthread_mutex_lock(&glLock);
	CGLContextObj		cgl_ctx = [[self openGLContext] CGLContextObj];
	CGFloat			tmpVals[4];
	[calibratedColor getComponents:(CGFloat *)tmpVals];
	for (int i=0;i<4;++i)
		clearColor[i] = tmpVals[i];
	glClearColor(clearColor[0],clearColor[1],clearColor[2],clearColor[3]);
	pthread_mutex_unlock(&glLock);
}
- (NSColor *) clearColor	{
	if (deleted)
		return nil;
	return [NSColor colorWithDeviceRed:clearColor[0] green:clearColor[1] blue:clearColor[2] alpha:clearColor[3]];
}
@synthesize drawBorder;
- (void) setBorderColor:(NSColor *)c	{
	if ((deleted)||(c==nil))
		return;
	NSColorSpace	*devRGBColorSpace = [NSColorSpace deviceRGBColorSpace];
	NSColor			*calibratedColor = ((void *)[c colorSpace]==(void *)devRGBColorSpace) ? c :[c colorUsingColorSpaceName:NSDeviceRGBColorSpace];
	pthread_mutex_lock(&glLock);
	//CGLContextObj		cgl_ctx = [[self openGLContext] CGLContextObj];
	[calibratedColor getComponents:(CGFloat *)borderColor];
	//glClearColor(clearColor[0],clearColor[1],clearColor[2],clearColor[3]);
	pthread_mutex_unlock(&glLock);
}
- (NSColor *) borderColor	{
	if (deleted)
		return nil;
	return [NSColor colorWithDeviceRed:borderColor[0] green:borderColor[1] blue:borderColor[2] alpha:borderColor[3]];
}
@synthesize mouseDownModifierFlags;
@synthesize mouseDownEventType;
@synthesize modifierFlags;
@synthesize mouseIsDown;
@synthesize flushMode;


@end
