/*
	    File: main.m
	Abstract: Main file.
	 Version: 1.1
	
	Disclaimer: IMPORTANT:  This Apple software is supplied to you by Apple
	Inc. ("Apple") in consideration of your agreement to the following
	terms, and your use, installation, modification or redistribution of
	this Apple software constitutes acceptance of these terms.  If you do
	not agree with these terms, please do not use, install, modify or
	redistribute this Apple software.
	
	In consideration of your agreement to abide by the following terms, and
	subject to these terms, Apple grants you a personal, non-exclusive
	license, under Apple's copyrights in this original Apple software (the
	"Apple Software"), to use, reproduce, modify and redistribute the Apple
	Software, with or without modifications, in source and/or binary forms;
	provided that if you redistribute the Apple Software in its entirety and
	without modifications, you must retain this notice and the following
	text and disclaimers in all such redistributions of the Apple Software.
	Neither the name, trademarks, service marks or logos of Apple Inc. may
	be used to endorse or promote products derived from the Apple Software
	without specific prior written permission from Apple.  Except as
	expressly stated in this notice, no other rights or licenses, express or
	implied, are granted by Apple herein, including but not limited to any
	patent rights that may be infringed by your derivative works or by other
	works in which the Apple Software may be incorporated.
	
	The Apple Software is provided by Apple on an "AS IS" basis.  APPLE
	MAKES NO WARRANTIES, EXPRESS OR IMPLIED, INCLUDING WITHOUT LIMITATION
	THE IMPLIED WARRANTIES OF NON-INFRINGEMENT, MERCHANTABILITY AND FITNESS
	FOR A PARTICULAR PURPOSE, REGARDING THE APPLE SOFTWARE OR ITS USE AND
	OPERATION ALONE OR IN COMBINATION WITH YOUR PRODUCTS.
	
	IN NO EVENT SHALL APPLE BE LIABLE FOR ANY SPECIAL, INDIRECT, INCIDENTAL
	OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF
	SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS
	INTERRUPTION) ARISING IN ANY WAY OUT OF THE USE, REPRODUCTION,
	MODIFICATION AND/OR DISTRIBUTION OF THE APPLE SOFTWARE, HOWEVER CAUSED
	AND WHETHER UNDER THEORY OF CONTRACT, TORT (INCLUDING NEGLIGENCE),
	STRICT LIABILITY OR OTHERWISE, EVEN IF APPLE HAS BEEN ADVISED OF THE
	POSSIBILITY OF SUCH DAMAGE.
	
	Copyright (C) 2009 Apple Inc. All Rights Reserved.
	
*/

#import <Cocoa/Cocoa.h>
#import <Quartz/Quartz.h>

#define kRendererEventMask (NSLeftMouseDownMask | NSLeftMouseDraggedMask | NSLeftMouseUpMask | NSRightMouseDownMask | NSRightMouseDraggedMask | NSRightMouseUpMask | NSOtherMouseDownMask | NSOtherMouseUpMask | NSOtherMouseDraggedMask | NSKeyDownMask | NSKeyUpMask | NSFlagsChangedMask | NSScrollWheelMask | NSTabletPointMask | NSTabletProximityMask)
#define kRendererFPS 60.0

@interface QCPatch
	+ (void)loadPlugInsInFolder:(NSString *)pluginFolder;
@end

@interface PlayerApplication : NSApplication <NSApplicationDelegate>
{
	NSOpenGLContext*			_openGLContext;
	QCRenderer*					_renderer;
	CGDirectDisplayID			_display;	
	NSString*					_filePath;
	NSTimer*					_renderTimer;
	NSTimeInterval				_startTime;
	NSSize						_screenSize;
	NSPoint						_mouseLocation;
}
@end

@implementation PlayerApplication

- (id) init
{
	//We need to be our own delegate
	if(self = [super init])
	[self setDelegate:self];
	
	// Load "skanky" plugins in our bundle's resource folder
	[QCPatch loadPlugInsInFolder: [[[NSBundle mainBundle] resourcePath] stringByAppendingPathComponent: @"Patches"] ];

	// List and load official api plugins in our bundle's resource folder
	NSString *pluginsDir = [[[NSBundle mainBundle] resourcePath] stringByAppendingPathComponent: @"Plug-Ins"];
	NSFileManager *localFileManager = [[NSFileManager alloc] init];
	NSDirectoryEnumerator *dirEnum = [localFileManager enumeratorAtPath:pluginsDir];
	
	NSString *file;
	while (file = [dirEnum nextObject]) {
		if ([[file pathExtension] isEqualToString: @"plugin"]) {
			// load the document
			[QCPlugIn loadPlugInAtPath: [pluginsDir stringByAppendingPathComponent:file] ];
			NSLog(@"Loading PlugIn `%@`", file );
		}
	}
	[localFileManager release];
	
	return self;
}

- (BOOL) application:(NSApplication*)theApplication openFile:(NSString*)filename
{
	//Let's remember the file for later
	_filePath = [filename retain];
	
	return YES;
}

- (void) applicationDidFinishLaunching:(NSNotification*)aNotification 
{
	GLint							value = 1;
	NSOpenGLPixelFormatAttribute	attributes[] = {
														NSOpenGLPFAFullScreen,
														NSOpenGLPFAScreenMask, CGDisplayIDToOpenGLDisplayMask(kCGDirectMainDisplay),
														NSOpenGLPFANoRecovery,
														NSOpenGLPFADoubleBuffer,
														NSOpenGLPFAAccelerated,
														NSOpenGLPFADepthSize, 24,
														(NSOpenGLPixelFormatAttribute) 0
													};
	NSOpenGLPixelFormat*			format;
	NSOpenPanel*					openPanel;
	int								displayNr;
	CGDirectDisplayID				*activeDisplays = nil;
	CGDisplayCount					displayCount = 0;
	
	// See if a Composition path is specified in Info.plist, and make sure it is an absolute path or a path to a resource
	_filePath = [[[[NSBundle mainBundle] objectForInfoDictionaryKey:@"Composition"] stringByExpandingTildeInPath] retain];
	if(_filePath != nil) {
		if([[NSBundle mainBundle] pathForResource:_filePath ofType:@""] != nil)
			_filePath = [[[NSBundle mainBundle] pathForResource:_filePath ofType:@""] retain];
		else {
			if(![_filePath isAbsolutePath]) 
				_filePath = [[ [[[NSBundle mainBundle] bundlePath] stringByDeletingLastPathComponent] stringByAppendingPathComponent:_filePath] retain];
			
			if(![[NSFileManager defaultManager] fileExistsAtPath:_filePath]) {
				NSLog(@"Specified file not found: %@", _filePath);
				_filePath = nil;
			}
		}		
	}
	
	// If no composition file was dropped on the application's icon or specified in Info.plist, we need to ask the user for one
	if(_filePath == nil) {
		openPanel = [NSOpenPanel openPanel];
		[openPanel setAllowsMultipleSelection:NO];
		[openPanel setCanChooseDirectories:NO];
		[openPanel setCanChooseFiles:YES];
		if([openPanel runModalForDirectory:nil file:nil types:[NSArray arrayWithObject:@"qtz"]] != NSOKButton) {
			NSLog(@"No composition file specified");
			[NSApp terminate:nil];
		}
		_filePath = [[openPanel filename] retain];
	}

	// See if a display was specified in Info.plist
	_display = kCGDirectMainDisplay;

	displayNr = [[[NSBundle mainBundle] objectForInfoDictionaryKey:@"Display Nr"] intValue];
	if(displayNr != 0) {
		// First count the nr of active displays
		CGGetActiveDisplayList(0, NULL, &displayCount);	
		
		if(displayNr>=displayCount) {
			NSLog(@"Cannot get display nr %d", displayNr);
		} else {
			// Allocate enough memory to hold all the display IDs we have
			activeDisplays = calloc((size_t)displayCount, sizeof(CGDirectDisplayID));
			
			if(CGGetActiveDisplayList(displayCount, activeDisplays, &displayCount) != CGDisplayNoErr) {
				NSLog(@"Cannot get active display list");
				[NSApp terminate:nil];
			}
			
			_display = activeDisplays[displayNr];
			free(activeDisplays);
		}
	}	
	
	// Capture the screen and cache its dimensions
	CGDisplayCapture(_display);
	CGDisplayHideCursor(_display);
	_screenSize.width = CGDisplayPixelsWide(_display);
	_screenSize.height = CGDisplayPixelsHigh(_display);
	
	// Init the OpenGL pixel format
	attributes[2] = CGDisplayIDToOpenGLDisplayMask(_display);
	format = [[[NSOpenGLPixelFormat alloc] initWithAttributes:attributes] autorelease];
	
	// Create the fullscreen OpenGL context on the main screen (double-buffered with color and depth buffers)
	_openGLContext = [[NSOpenGLContext alloc] initWithFormat:format shareContext:nil];
	if(_openGLContext == nil) {
		NSLog(@"Cannot create OpenGL context");
		[NSApp terminate:nil];
	}
	[_openGLContext setFullScreen];
	[_openGLContext setValues:&value forParameter:kCGLCPSwapInterval];
	
	// Create the QuartzComposer Renderer with that OpenGL context and the specified composition file
	_renderer = [[QCRenderer alloc] initWithOpenGLContext:_openGLContext pixelFormat:format file:_filePath];
	if(_renderer == nil) {
		NSLog(@"Cannot create QCRenderer");
		[NSApp terminate:nil];
	}
	
	// See if any of the published inputs are set in Info.plist
	for(NSString *keyName in [_renderer inputKeys]) {
		NSString *keyValue = [[NSBundle mainBundle] objectForInfoDictionaryKey:keyName];
		if(keyValue != nil) {
			NSLog(@"Setting key `%@` to `%@`", keyName, keyValue );
			[_renderer setValue:keyValue forInputKey:keyName];
		}
	}
	
	// Create a timer which will regularly call our rendering method
	_renderTimer = [[NSTimer scheduledTimerWithTimeInterval:(1.0 / (NSTimeInterval)kRendererFPS) target:self selector:@selector(_render:) userInfo:nil repeats:YES] retain];
	if(_renderTimer == nil) {
		NSLog(@"Cannot create NSTimer");
		[NSApp terminate:nil];
	}
}

- (void) renderWithEvent:(NSEvent*)event
{
	NSTimeInterval			time = [NSDate timeIntervalSinceReferenceDate];
	NSPoint					mouseLocation;
	NSMutableDictionary*	arguments;
	

	// Let's compute our local time
	if(_startTime == 0) {
		_startTime = time;
		time = 0;
	}
	else
		time -= _startTime;
	
	// We setup the arguments to pass to the composition (normalized mouse coordinates and an optional event)
	mouseLocation = [NSEvent mouseLocation];
	mouseLocation.x /= _screenSize.width;
	mouseLocation.y /= _screenSize.height;
	arguments = [NSMutableDictionary dictionaryWithObject:[NSValue valueWithPoint:mouseLocation] forKey:QCRendererMouseLocationKey];
	
	if(mouseLocation.x != _mouseLocation.x || mouseLocation.y != _mouseLocation.y) {
		if(!event){
			// Manually create a MouseMoved event to force the Mouse patch position to update 
			event = [NSEvent mouseEventWithType:NSMouseMoved
					location:[NSEvent mouseLocation]
					modifierFlags:0
					timestamp:[NSDate timeIntervalSinceReferenceDate]
					windowNumber:0
					context:[NSGraphicsContext currentContext]
					eventNumber:1
					clickCount:1
					pressure:0.0
			];
		}
		_mouseLocation.x = mouseLocation.x;
		_mouseLocation.y = mouseLocation.y;
	}
	
	if(event)
		[arguments setObject:event forKey:QCRendererEventKey];

	
	// Render a frame
	if(![_renderer renderAtTime:time arguments:arguments])
		NSLog(@"Rendering failed at time %.3fs", time);
	
	// Flush the OpenGL context to display the frame on screen
	[_openGLContext flushBuffer];
}

- (void) _render:(NSTimer*)timer
{
	// Simply call our rendering method, passing no event to the composition
	[self renderWithEvent:nil];
}

- (void) sendEvent:(NSEvent*)event
{
	// If the user pressed the [Esc] key, we need to exit
	if(([event type] == NSKeyDown) && ([event keyCode] == 0x35))
	[NSApp terminate:nil];
	
	// If the renderer is active and we have a meaningful event, render immediately passing that event to the composition
	if(_renderer && (NSEventMaskFromType([event type]) & kRendererEventMask))
		[self renderWithEvent:event];
	else
		[super sendEvent:event];
}

- (void) applicationWillTerminate:(NSNotification*)aNotification 
{
	// Stop the timer
	[_renderTimer invalidate];
	[_renderTimer release];
	
	// Destroy the renderer
	[_renderer release];
	
	// Destroy the OpenGL context
	[_openGLContext clearDrawable];
	[_openGLContext release];
	
	// Release the display
	if(CGDisplayIsCaptured(_display)) {
		CGDisplayShowCursor(_display);
		CGDisplayRelease(_display);
	}
	
	// Release path
	[_filePath release];
}

@end

int main(int argc, const char *argv[])
{
    return NSApplicationMain(argc, argv);
}
