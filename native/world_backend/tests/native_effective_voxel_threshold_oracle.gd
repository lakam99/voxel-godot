extends SceneTree

func _initialize() -> void:
	const DENSITY := -10.567796868800928
	const CELL := 1.35
	var buffer := VoxelBuffer.new()
	buffer.create(1, 1, 1)
	buffer.set_channel_depth(VoxelBuffer.CHANNEL_SDF, VoxelBuffer.DEPTH_16_BIT)
	buffer.set_voxel_f(-DENSITY / CELL, 0, 0, 0, VoxelBuffer.CHANNEL_SDF)
	var bytes := buffer.get_channel_as_byte_array(VoxelBuffer.CHANNEL_SDF)
	print("VWB_VOXEL_THRESHOLD_ORACLE:", JSON.stringify({"density": DENSITY, "input": -DENSITY / CELL, "raw": buffer.get_voxel(0, 0, 0, VoxelBuffer.CHANNEL_SDF), "bytes": Array(bytes)}))
	quit()
