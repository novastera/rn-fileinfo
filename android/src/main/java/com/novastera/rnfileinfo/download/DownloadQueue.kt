package com.novastera.rnfileinfo.download

import com.facebook.react.bridge.ReactContext
import java.lang.ref.WeakReference
import java.util.LinkedList
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.Executors

/**
 * Bounded download scheduler with FIFO waiting queue.
 * Max 4 concurrent downloads (configurable).
 */
class DownloadQueue(private val contextRef: WeakReference<ReactContext>) {

    companion object {
        private const val MAX_CONCURRENT = 4
    }

    private val executor = Executors.newFixedThreadPool(MAX_CONCURRENT)
    private val workers = ConcurrentHashMap<String, DownloadWorker>()
    private val waitingQueue = LinkedList<DownloadTask>()
    private val queueLock = Object()

    /**
     * Enqueue a download task. Starts immediately if under concurrency limit,
     * otherwise queues for later.
     */
    fun enqueue(task: DownloadTask) {
        synchronized(queueLock) {
            if (workers.size < MAX_CONCURRENT) {
                startWorker(task)
            } else {
                waitingQueue.add(task)
            }
        }
    }

    /**
     * Pause a running download by interrupting its worker.
     */
    fun pause(id: String) {
        synchronized(queueLock) {
            // Check if it's in the waiting queue first
            waitingQueue.removeAll { it.id == id }

            // Stop running worker
            workers[id]?.pause()
            workers.remove(id)
        }
    }

    /**
     * Cancel a download — pause + clean up files.
     */
    fun cancel(id: String) {
        pause(id)
        DownloadRegistry.get(id)?.let { task ->
            java.io.File(task.destinationPath).delete()
            DownloadRegistry.deleteMetadata(task)
            DownloadRegistry.remove(id)
        }
    }

    /**
     * Called when a download finishes (success, failure, or pause).
     * Starts the next queued download if available.
     */
    fun onDownloadFinished(id: String) {
        synchronized(queueLock) {
            workers.remove(id)
            val next = waitingQueue.poll()
            if (next != null) {
                startWorker(next)
            }
        }
    }

    /**
     * Shut down the executor and clear all state.
     */
    fun shutdown() {
        executor.shutdownNow()
        workers.clear()
        synchronized(queueLock) {
            waitingQueue.clear()
        }
    }

    private fun startWorker(task: DownloadTask) {
        val worker = DownloadWorker(task, this, contextRef)
        workers[task.id] = worker
        executor.submit(worker)
    }
}
