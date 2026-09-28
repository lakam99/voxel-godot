extends SceneTree

# Independent installed-Godot/Voxel Tools oracle for the C++ block encoder.
# The source test asserts these bytes; this script does not call native code.
func _initialize() -> void:
	var buffer := VoxelBuffer.new()
	buffer.create(2, 2, 2)
	buffer.set_channel_depth(VoxelBuffer.CHANNEL_SDF, VoxelBuffer.DEPTH_16_BIT)
	buffer.set_channel_depth(VoxelBuffer.CHANNEL_INDICES, VoxelBuffer.DEPTH_8_BIT)
	buffer.set_channel_depth(VoxelBuffer.CHANNEL_DATA5, VoxelBuffer.DEPTH_8_BIT)
	var densities := [0.0, -1.35, 1.35, -1.35, 675.0, -675.0, 1.35, 0.0]
	var materials := [1, 0, 13, 3, 7, 15, 3, 2]
	var i := 0
	for z in range(2):
		for x in range(2):
			for y in range(2):
				buffer.set_voxel_f(-float(densities[i]) / 1.35, x, y, z, VoxelBuffer.CHANNEL_SDF)
				buffer.set_voxel(materials[i], x, y, z, VoxelBuffer.CHANNEL_INDICES)
				buffer.set_voxel(materials[i], x, y, z, VoxelBuffer.CHANNEL_DATA5)
				i += 1
	print("VWB_VOXEL_BYTE_ORACLE:", JSON.stringify({
		"sdf": Array(buffer.get_channel_as_byte_array(VoxelBuffer.CHANNEL_SDF)),
		"indices": Array(buffer.get_channel_as_byte_array(VoxelBuffer.CHANNEL_INDICES)),
		"data5": Array(buffer.get_channel_as_byte_array(VoxelBuffer.CHANNEL_DATA5)),
	}))
	quit()
